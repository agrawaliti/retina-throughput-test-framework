package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/signal"
	"runtime"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

type counters struct {
	accepted uint64
	active   int64
	bytes    uint64
	errors   uint64
}

func main() {
	var (
		listenAddr = flag.String("listen-addr", ":9000", "listen address")
		listeners  = flag.Int("listeners", runtime.NumCPU(), "number of SO_REUSEPORT listeners")
		workers    = flag.Int("workers", runtime.NumCPU()*4, "number of connection workers")
		bufSize    = flag.Int("buffer-size", 64*1024, "per-connection read buffer bytes")
		report     = flag.Duration("report-interval", 5*time.Second, "stats report interval")
	)
	flag.Parse()

	if *listeners <= 0 || *workers <= 0 || *bufSize <= 0 {
		log.Fatal("listeners, workers, and buffer-size must be > 0")
	}

	log.Printf("starting reuseport receiver addr=%s listeners=%d workers=%d gomaxprocs=%d", *listenAddr, *listeners, *workers, runtime.GOMAXPROCS(0))

	lc := net.ListenConfig{
		Control: func(network, address string, raw syscall.RawConn) error {
			var controlErr error
			err := raw.Control(func(fd uintptr) {
				controlErr = syscall.SetsockoptInt(int(fd), syscall.SOL_SOCKET, syscall.SO_REUSEADDR, 1)
				if controlErr != nil {
					return
				}
				controlErr = syscall.SetsockoptInt(int(fd), syscall.SOL_SOCKET, 0x0F, 1)
			})
			if err != nil {
				return err
			}
			return controlErr
		},
	}

	conns := make(chan net.Conn, *workers*4)
	stats := &counters{}

	var workerWG sync.WaitGroup
	for workerID := 0; workerID < *workers; workerID++ {
		workerWG.Add(1)
		go func() {
			defer workerWG.Done()
			buf := make([]byte, *bufSize)
			for conn := range conns {
				atomic.AddInt64(&stats.active, 1)
				for {
					n, err := conn.Read(buf)
					if n > 0 {
						atomic.AddUint64(&stats.bytes, uint64(n))
					}
					if err != nil {
						if !errors.Is(err, io.EOF) {
							atomic.AddUint64(&stats.errors, 1)
						}
						_ = conn.Close()
						atomic.AddInt64(&stats.active, -1)
						break
					}
				}
			}
		}()
	}

	listenersList := make([]net.Listener, 0, *listeners)
	for listenerID := 0; listenerID < *listeners; listenerID++ {
		ln, err := lc.Listen(nil, "tcp", *listenAddr)
		if err != nil {
			log.Fatalf("listen %d/%d failed: %v", listenerID+1, *listeners, err)
		}
		listenersList = append(listenersList, ln)
		go acceptLoop(listenerID, ln, conns, stats)
	}

	ticker := time.NewTicker(*report)
	defer ticker.Stop()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, os.Interrupt, syscall.SIGTERM)

	started := time.Now()
	var lastBytes uint64
	for {
		select {
		case sig := <-sigCh:
			log.Printf("received signal %s, shutting down", sig)
			for _, ln := range listenersList {
				_ = ln.Close()
			}
			close(conns)
			workerWG.Wait()
			return
		case <-ticker.C:
			totalBytes := atomic.LoadUint64(&stats.bytes)
			deltaBytes := totalBytes - lastBytes
			lastBytes = totalBytes
			gbps := float64(deltaBytes*8) / report.Seconds() / 1e9
			log.Printf(
				"stats uptime=%s accepted=%d active=%d bytes=%d errors=%d interval_gbps=%.2f",
				time.Since(started).Truncate(time.Second),
				atomic.LoadUint64(&stats.accepted),
				atomic.LoadInt64(&stats.active),
				totalBytes,
				atomic.LoadUint64(&stats.errors),
				gbps,
			)
		}
	}
}

func acceptLoop(id int, ln net.Listener, conns chan<- net.Conn, stats *counters) {
	for {
		conn, err := ln.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return
			}
			var netErr net.Error
			if errors.As(err, &netErr) && netErr.Temporary() {
				log.Printf("listener=%d temporary accept error: %v", id, err)
				time.Sleep(50 * time.Millisecond)
				continue
			}
			log.Printf("listener=%d accept error: %v", id, err)
			return
		}
		atomic.AddUint64(&stats.accepted, 1)
		if tcpConn, ok := conn.(*net.TCPConn); ok {
			_ = tcpConn.SetReadBuffer(4 * 1024 * 1024)
			_ = tcpConn.SetNoDelay(true)
		}
		select {
		case conns <- conn:
		default:
			atomic.AddUint64(&stats.errors, 1)
			log.Printf("listener=%d dropping connection because worker queue is full", id)
			_ = conn.Close()
		}
	}
}

func init() {
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)
	log.SetPrefix(fmt.Sprintf("pid=%d ", os.Getpid()))
}
