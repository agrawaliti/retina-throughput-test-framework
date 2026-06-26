package main

import (
	"context"
	"encoding/json"
	"flag"
	"net"
	"os"
	"runtime"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

type result struct {
	Target          string  `json:"target"`
	Connections     int     `json:"connections"`
	DurationSeconds int     `json:"duration_seconds"`
	PayloadBytes    int     `json:"payload_bytes"`
	BytesSent       uint64  `json:"bytes_sent"`
	BitsPerSecond   float64 `json:"bits_per_second"`
	ConnectErrors   uint64  `json:"connect_errors"`
	WriteErrors     uint64  `json:"write_errors"`
	GOMAXPROCS      int     `json:"gomaxprocs"`
	TimestampUTC    string  `json:"timestamp_utc"`
}

func main() {
	var (
		target      = flag.String("target", "127.0.0.1:9000", "receiver host:port")
		connections = flag.Int("connections", 64, "number of long-lived TCP connections")
		duration    = flag.Duration("duration", 30*time.Second, "run duration")
		payloadSize = flag.Int("payload-bytes", 64*1024, "bytes written per write call")
	)
	flag.Parse()

	if *connections <= 0 || *payloadSize <= 0 || *duration <= 0 {
		panic("connections, duration, and payload-bytes must be > 0")
	}

	ctx, cancel := context.WithTimeout(context.Background(), *duration)
	defer cancel()

	payload := make([]byte, *payloadSize)
	var bytesSent uint64
	var connectErrors uint64
	var writeErrors uint64

	dialer := net.Dialer{
		Control: func(network, address string, raw syscall.RawConn) error {
			var controlErr error
			err := raw.Control(func(fd uintptr) {
				controlErr = syscall.SetsockoptInt(int(fd), syscall.IPPROTO_TCP, syscall.TCP_NODELAY, 1)
			})
			if err != nil {
				return err
			}
			return controlErr
		},
	}

	var wg sync.WaitGroup
	start := time.Now()
	for connID := 0; connID < *connections; connID++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			conn, err := dialer.DialContext(ctx, "tcp", *target)
			if err != nil {
				atomic.AddUint64(&connectErrors, 1)
				return
			}
			defer conn.Close()

			if tcpConn, ok := conn.(*net.TCPConn); ok {
				_ = tcpConn.SetWriteBuffer(4 * 1024 * 1024)
				_ = tcpConn.SetNoDelay(true)
			}

			for {
				select {
				case <-ctx.Done():
					return
				default:
				}

				n, err := conn.Write(payload)
				if n > 0 {
					atomic.AddUint64(&bytesSent, uint64(n))
				}
				if err != nil {
					atomic.AddUint64(&writeErrors, 1)
					return
				}
			}
		}()
	}

	wg.Wait()
	elapsed := time.Since(start)
	if elapsed <= 0 {
		elapsed = *duration
	}

	out := result{
		Target:          *target,
		Connections:     *connections,
		DurationSeconds: int(duration.Seconds()),
		PayloadBytes:    *payloadSize,
		BytesSent:       atomic.LoadUint64(&bytesSent),
		BitsPerSecond:   float64(atomic.LoadUint64(&bytesSent)*8) / elapsed.Seconds(),
		ConnectErrors:   atomic.LoadUint64(&connectErrors),
		WriteErrors:     atomic.LoadUint64(&writeErrors),
		GOMAXPROCS:      runtime.GOMAXPROCS(0),
		TimestampUTC:    time.Now().UTC().Format(time.RFC3339),
	}

	encoder := json.NewEncoder(os.Stdout)
	if err := encoder.Encode(out); err != nil {
		panic(err)
	}
}
