package main

import (
	"bytes"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"sync"
	"time"

	"github.com/hashicorp/yamux"
)

var port = "4000"

type TestResult struct {
	Name   string  `json:"name"`
	Passed bool    `json:"passed"`
	Error  string  `json:"error,omitempty"`
	Mbps   float64 `json:"mbps,omitempty"`
	Secs   float64 `json:"secs,omitempty"`
}

type TestReport struct {
	Results []TestResult `json:"results"`
	Passed  int          `json:"passed"`
	Failed  int          `json:"failed"`
}

func main() {
	if len(os.Args) > 1 {
		port = os.Args[1]
	}

	report := TestReport{}

	run := func(name string, fn func() (*TestResult, error)) {
		result := TestResult{Name: name}
		extra, err := fn()
		if err != nil {
			result.Passed = false
			result.Error = err.Error()
			report.Failed++
		} else {
			result.Passed = true
			report.Passed++
		}
		if extra != nil {
			result.Mbps = extra.Mbps
			result.Secs = extra.Secs
		}
		report.Results = append(report.Results, result)
	}

	session := dial()
	defer session.Close()

	// ----- echo tests (single session) -----
	run("echo/small", func() (*TestResult, error) {
		return nil, testEcho(session, "hello from go")
	})

	run("echo/empty", func() (*TestResult, error) {
		return nil, testEcho(session, "")
	})

	run("echo/1byte", func() (*TestResult, error) {
		return nil, testEcho(session, "x")
	})

	run("echo/1kb", func() (*TestResult, error) {
		return nil, testEchoBytes(session, makeBytes(1024))
	})

	run("echo/64kb", func() (*TestResult, error) {
		return nil, testEchoBytes(session, makeBytes(64*1024))
	})

	run("echo/256kb", func() (*TestResult, error) {
		return nil, testEchoBytes(session, makeBytes(256*1024))
	})

	// ----- concurrent streams (single session) -----
	run("streams/10", func() (*TestResult, error) {
		return nil, testConcurrentStreams(session, 10)
	})

	run("streams/50", func() (*TestResult, error) {
		return nil, testConcurrentStreams(session, 50)
	})

	// ----- rapid fire (single session) -----
	run("rapid/100", func() (*TestResult, error) {
		return nil, testRapidFire(session, 100)
	})

	// ----- ping -----
	run("ping", func() (*TestResult, error) {
		rtt, err := session.Ping()
		if err != nil {
			return nil, err
		}
		return &TestResult{Secs: rtt.Seconds()}, nil
	})

	// ----- concurrent sessions -----
	run("sessions/5x1", func() (*TestResult, error) {
		return nil, testConcurrentSessions(5, 1)
	})

	run("sessions/5x10", func() (*TestResult, error) {
		return nil, testConcurrentSessions(5, 10)
	})

	run("sessions/10x10", func() (*TestResult, error) {
		return nil, testConcurrentSessions(10, 10)
	})

	run("sessions/10x50", func() (*TestResult, error) {
		return nil, testConcurrentSessions(10, 50)
	})

	// ----- concurrent sessions with large payloads -----
	run("sessions_large/5x64kb", func() (*TestResult, error) {
		return nil, testConcurrentSessionsLarge(5, 64*1024)
	})

	run("sessions_large/3x256kb", func() (*TestResult, error) {
		return nil, testConcurrentSessionsLarge(3, 256*1024)
	})

	// ----- throughput benchmark -----
	run("throughput/1gb", func() (*TestResult, error) {
		return testThroughput(1024 * 1024 * 1024)
	})

	out, _ := json.Marshal(report)
	fmt.Println(string(out))

	if report.Failed > 0 {
		os.Exit(1)
	}
}

// ---------------------------------------------------------------------------
// Helpers

func dial() *yamux.Session {
	conn, err := net.Dial("tcp", "localhost:"+port)
	if err != nil {
		panic(fmt.Sprintf("dial: %s", err))
	}

	session, err := yamux.Client(conn, nil)
	if err != nil {
		panic(fmt.Sprintf("yamux client: %s", err))
	}

	return session
}

func makeBytes(n int) []byte {
	buf := make([]byte, n)
	rand.Read(buf)
	return buf
}

// ---------------------------------------------------------------------------
// Test helpers

func testEcho(session *yamux.Session, msg string) error {
	stream, err := session.Open()
	if err != nil {
		return fmt.Errorf("open: %w", err)
	}
	defer stream.Close()

	if len(msg) == 0 {
		return nil
	}

	_, err = stream.Write([]byte(msg))
	if err != nil {
		return fmt.Errorf("write: %w", err)
	}

	buf := make([]byte, len(msg))
	_, err = io.ReadFull(stream, buf)
	if err != nil {
		return fmt.Errorf("read: %w", err)
	}

	if string(buf) != msg {
		return fmt.Errorf("mismatch: got %q, want %q", string(buf), msg)
	}

	return nil
}

func testEchoBytes(session *yamux.Session, data []byte) error {
	stream, err := session.Open()
	if err != nil {
		return fmt.Errorf("open: %w", err)
	}
	defer stream.Close()

	if len(data) == 0 {
		return nil
	}

	errCh := make(chan error, 1)
	go func() {
		_, err := stream.Write(data)
		errCh <- err
	}()

	buf := make([]byte, len(data))
	_, err = io.ReadFull(stream, buf)
	if err != nil {
		return fmt.Errorf("read: %w", err)
	}

	if err := <-errCh; err != nil {
		return fmt.Errorf("write: %w", err)
	}

	if !bytes.Equal(buf, data) {
		return fmt.Errorf("mismatch: %d bytes sent, got different content back", len(data))
	}

	return nil
}

func testConcurrentStreams(session *yamux.Session, n int) error {
	var wg sync.WaitGroup
	errs := make(chan error, n)

	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			msg := fmt.Sprintf("stream-%d-payload", i)
			if err := testEcho(session, msg); err != nil {
				errs <- fmt.Errorf("stream %d: %w", i, err)
			}
		}(i)
	}

	wg.Wait()
	close(errs)

	for err := range errs {
		return err
	}
	return nil
}

func testRapidFire(session *yamux.Session, n int) error {
	stream, err := session.Open()
	if err != nil {
		return fmt.Errorf("open: %w", err)
	}
	defer stream.Close()

	for i := 0; i < n; i++ {
		msg := fmt.Sprintf("msg-%04d", i)

		_, err = stream.Write([]byte(msg))
		if err != nil {
			return fmt.Errorf("write %d: %w", i, err)
		}

		buf := make([]byte, len(msg))
		stream.SetReadDeadline(time.Now().Add(5 * time.Second))
		_, err = io.ReadFull(stream, buf)
		if err != nil {
			return fmt.Errorf("read %d: %w", i, err)
		}

		if string(buf) != msg {
			return fmt.Errorf("msg %d: got %q, want %q", i, string(buf), msg)
		}
	}

	return nil
}

func testConcurrentSessions(numSessions, streamsPerSession int) error {
	var wg sync.WaitGroup
	errs := make(chan error, numSessions)

	for s := 0; s < numSessions; s++ {
		wg.Add(1)
		go func(s int) {
			defer wg.Done()

			session := dial()
			defer session.Close()

			if err := testConcurrentStreams(session, streamsPerSession); err != nil {
				errs <- fmt.Errorf("session %d: %w", s, err)
			}
		}(s)
	}

	wg.Wait()
	close(errs)

	for err := range errs {
		return err
	}
	return nil
}

func testConcurrentSessionsLarge(numSessions, payloadSize int) error {
	var wg sync.WaitGroup
	errs := make(chan error, numSessions)

	for s := 0; s < numSessions; s++ {
		wg.Add(1)
		go func(s int) {
			defer wg.Done()

			session := dial()
			defer session.Close()

			data := makeBytes(payloadSize)
			if err := testEchoBytes(session, data); err != nil {
				errs <- fmt.Errorf("session %d: %w", s, err)
			}
		}(s)
	}

	wg.Wait()
	close(errs)

	for err := range errs {
		return err
	}
	return nil
}

func testThroughput(totalBytes int) (*TestResult, error) {
	session := dial()
	defer session.Close()

	stream, err := session.Open()
	if err != nil {
		return nil, fmt.Errorf("open: %w", err)
	}
	defer stream.Close()

	chunk := make([]byte, 64*1024)
	rand.Read(chunk)

	writeErr := make(chan error, 1)
	go func() {
		remaining := totalBytes
		for remaining > 0 {
			n := len(chunk)
			if n > remaining {
				n = remaining
			}
			_, err := stream.Write(chunk[:n])
			if err != nil {
				writeErr <- fmt.Errorf("write: %w", err)
				return
			}
			remaining -= n
		}
		writeErr <- nil
	}()

	start := time.Now()
	buf := make([]byte, 64*1024)
	received := 0
	for received < totalBytes {
		n, err := stream.Read(buf)
		if err != nil {
			return nil, fmt.Errorf("read at %d/%d: %w", received, totalBytes, err)
		}
		received += n
	}
	elapsed := time.Since(start)

	if err := <-writeErr; err != nil {
		return nil, err
	}

	mbits := float64(totalBytes) * 8 / 1_000_000
	secs := elapsed.Seconds()

	return &TestResult{Mbps: mbits / secs, Secs: secs}, nil
}
