// go-org side of the bench protocol (see bench/README.md):
//
//	go-org-runner <file.org> <warmup> <min-time-seconds>
//
// prints one ns-per-iteration line per measured parse; the orchestrator does the stats.
package main

import (
	"fmt"
	"io"
	"log"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/niklasfasching/go-org/org"
)

var sink int

func parseOnce(src, path string) {
	conf := org.New()
	// go-org logs recoverable oddities to stderr by default; a benchmark run on a large
	// corpus would drown in them, and logging is not parsing.
	conf.Log = log.New(io.Discard, "", 0)
	doc := conf.Parse(strings.NewReader(src), path)
	sink += len(doc.Nodes)
}

func main() {
	if len(os.Args) != 4 {
		fmt.Fprintln(os.Stderr, "usage: go-org-runner <file.org> <warmup> <min-time-seconds>")
		os.Exit(1)
	}
	data, err := os.ReadFile(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	src := string(data)
	warmup, err := strconv.Atoi(os.Args[2])
	if err != nil {
		fmt.Fprintln(os.Stderr, "warmup must be an integer")
		os.Exit(1)
	}
	minTime, err := strconv.ParseFloat(os.Args[3], 64)
	if err != nil {
		fmt.Fprintln(os.Stderr, "min-time must be a number")
		os.Exit(1)
	}

	for i := 0; i < warmup; i++ {
		parseOnce(src, os.Args[1])
	}

	t := time.Now()
	parseOnce(src, os.Args[1])
	est := time.Since(t).Seconds()
	iters := int(minTime / est)
	if iters < 5 {
		iters = 5
	}
	if iters > 20000 {
		iters = 20000
	}

	for i := 0; i < iters; i++ {
		t := time.Now()
		parseOnce(src, os.Args[1])
		fmt.Println(time.Since(t).Nanoseconds())
	}
	fmt.Fprintf(os.Stderr, "sink=%d\n", sink)
}
