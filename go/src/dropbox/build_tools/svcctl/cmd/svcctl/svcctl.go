package main

import (
	"bytes"
	"flag"
	"fmt"
	"io/ioutil"
	"os"
	"path"
	"sort"
	"strconv"
	"strings"
	"sync"
	"text/tabwriter"
	"text/template"
	"time"

	"dropbox/build_tools/svcctl/svclib"
	svclib_proto "dropbox/proto/build_tools/svclib"
)

type cmdFunc func(args []string)
type cmd struct {
	cmdFunc
	usage string
}

var cmdMap map[string]cmd

var doc = `svcctl - interact with the service controller

Additional details are available:
  svcctl help <cmd>
  svcctl <cmd> -h
`

func init() {
	cmdMap = map[string]cmd{
		"auto-restart": {cmdAutoRestart,
			`svcctl auto-restart
Automatically restart any services that have been rebuilt.`},
		"restart": {cmdRestart,
			`svcctl restart <service>`},
		"start": {cmdStart,
			`svcctl start <service>`},
		"start-all": {cmdStartAll,
			`svcctl start-all`},
		"status": {cmdStatus,
			`svcctl status [--all] <service>`},
		"stop": {cmdStop,
			`svcctl stop <service>`},
		"stop-all": {cmdStopAll,
			`svcctl stop-all`},
		"version-check": {cmdVersionCheck,
			`svcctl version-check
Explicitly invoke the automatic service definitions version check.`},
	}

	flag.Usage = func() {
		fmt.Fprintf(os.Stderr, "Usage of %s:\n", os.Args[0])
		fmt.Fprintf(os.Stderr, doc)
		fmt.Fprintln(os.Stderr)
		cmdNames := make([]string, 0, len(cmdMap))
		for name, _ := range cmdMap {
			cmdNames = append(cmdNames, name)
		}
		sort.Strings(cmdNames)
		for _, name := range cmdNames {
			usage := cmdMap[name].usage
			if usage == "" {
				usage = fmt.Sprintf("%v %v", path.Base(os.Args[0]), name)
			}
			fmt.Fprintln(os.Stderr, usage)
			fmt.Fprintln(os.Stderr)
		}
	}
}

func versionCheck() {
	currentVersion, currentErr := ioutil.ReadFile(svclib.CurrentServiceDefsVersionFile)
	if currentErr != nil {
		fatalf(`ERROR: Unable to read current version file at %s.
  This can happen if you "bzl itest-start //a/target/that/has/no/services".
  In other cases, please recreate the container.`, svclib.CurrentServiceDefsVersionFile)
	}
	frozenVersion, frozenErr := ioutil.ReadFile(svclib.FrozenServiceDefsVersionFile)
	if frozenErr != nil {
		fatalf("ERROR: Unable to read frozen version file at %s. Please recreate the container.", svclib.FrozenServiceDefsVersionFile)
	}
	if !bytes.Equal(currentVersion, frozenVersion) {
		fatalf("ERROR: Service definitions are stale or the service controller has changed. Please recreate the container.")
	}
}

func main() {
	flag.Parse()
	args := flag.Args()
	if len(args) == 0 {
		flag.Usage()
		os.Exit(2)
	}
	cmdName := args[0]
	args = args[1:]

	if cmdName == "help" {
		if len(args) > 0 {
			cmdName = args[0]
			args = []string{"-h"}
		}
	}
	versionCheck()

	if cmdEntry, ok := cmdMap[cmdName]; ok {
		cmdEntry.cmdFunc(args)
	} else {
		errorf("unrecognized command: %s\n", cmdName)
		flag.Usage()
		os.Exit(2)
	}
}

type flagSet struct {
	*flag.FlagSet
	name  string // Why is name private"
	usage string
}

// Sanity check args to prevent common errors.
func (fs *flagSet) Parse(args []string) error {
	if err := fs.FlagSet.Parse(args); err != nil {
		return err
	}
	for _, arg := range fs.Args() {
		if strings.HasPrefix(arg, "-") {
			return fmt.Errorf("invalid option after positional args: %v", arg)
		}
	}
	return nil
}

func (fs *flagSet) ParseOrDie(args []string) {
	if err := fs.Parse(args); err != nil {
		fatalf("%v: %v", fs.name, err)
	}
}

func newFlagSet(name string) *flagSet {
	fs := &flagSet{flag.NewFlagSet(name, flag.ExitOnError), name, cmdMap[name].usage}
	fs.Usage = func() {
		fmt.Fprintf(os.Stderr, "%v\n\nSubcommand flags:\n", fs.usage)
		fs.PrintDefaults()
	}
	return fs
}

func fatalf(str string, args ...interface{}) {
	errorf(str, args...)
	os.Exit(1)
}

func errorf(str string, args ...interface{}) {
	if str[len(str)-1] != '\n' {
		str = str + "\n"
	}
	fmt.Fprintf(os.Stderr, str, args...)
}

func cmdRestart(args []string) {
	flags := newFlagSet("restart")
	flags.ParseOrDie(args)

	for _, name := range flags.Args() {
		s, sErr := svclib.GetService(name)
		if sErr != nil {
			fatalf("restart failed: %s", sErr)
		}
		if err := s.Stop(); err != nil {
			fatalf("restart failed: %s", err)
		}
		if err := s.Start(); err != nil {
			fatalf("restart failed: %s", err)
		}
		fmt.Printf("restart successful: %s\n", name)
	}
}

func cmdStart(args []string) {
	flags := newFlagSet("start")
	flags.ParseOrDie(args)

	for _, name := range flags.Args() {
		s, sErr := svclib.GetService(name)
		if sErr != nil {
			fatalf("start failed: %s", sErr)
		}
		if err := s.Start(); err != nil {
			fatalf("start failed: %s", err)
		}
		fmt.Printf("start successful: %s\n", name)
	}
}

func cmdStartAll(args []string) {
	flags := newFlagSet("start-all")
	flags.ParseOrDie(args)
	if err := svclib.StartAll(); err != nil {
		fatalf("start failed: %s", err)
	}
	fmt.Printf("start all successful\n")
}

type serviceSlicebyName []svclib.Service

func (slice serviceSlicebyName) Len() int {
	return len(slice)
}

func (slice serviceSlicebyName) Less(i, j int) bool {
	return slice[i].Name() < slice[j].Name()
}

func (slice serviceSlicebyName) Swap(i, j int) {
	slice[i], slice[j] = slice[j], slice[i]
}

func cmdStatus(args []string) {
	var flagAll bool
	var flagRequiresRestartOnly bool
	var flagFormat string
	flags := newFlagSet("status")
	flags.BoolVar(&flagAll, "all", false,
		"Show the status of all services, including task services which are hidden by default.")
	flags.BoolVar(&flagRequiresRestartOnly, "requires-restart-only", false,
		"Only show services that requires a restart")
	flags.StringVar(&flagFormat, "format", "",
		"Use a Go template to display the output")
	flags.ParseOrDie(args)
	args = flags.Args()
	if len(args) > 0 {
		if len(args) != 1 {
			fatalf("Specify exactly one service, or don't specify any services.")
		}
		service, getErr := svclib.GetService(args[0])
		if getErr != nil {
			fatalf("status failed: %s", getErr)
		}
		if status, statusErr := service.Status(); statusErr != nil {
			fatalf("status failed: %s", statusErr)
		} else {
			statusString := strings.ToLower(status.StatusCode.String())
			if *status.NeedsRestart {
				fmt.Printf("%s - needs restart\n", statusString)
			} else {
				fmt.Printf("%s\n", statusString)
			}
			fmt.Printf("owner: %s\n", status.GetOwner())
			fmt.Printf("logs: %s\n", *status.LogFile)
		}
		return
	}

	var services serviceSlicebyName
	var listErr error
	services, listErr = svclib.ListServices()
	if listErr != nil {
		fatalf("status failed: %s", listErr)
	}
	sort.Sort(services)
	tabWriter := tabwriter.NewWriter(os.Stdout, 0, 4, 4, ' ', 0)
	type TemplateValues struct {
		Name         string
		NeedsRestart bool
		Owner        string
		Status       string
		Pid          int64
		CPUTime      string
		RssMb        string
	}
	if flagFormat == "" {
		fmt.Fprintln(tabWriter, "Service\tOwner\tStatus")
		flagFormat = "{{if .NeedsRestart}}*{{- end}}{{.Name}}\t{{.Owner}}\t{{.Status}}"
	}
	tmpl, tmplErr := template.New("svcctl").Parse(flagFormat)
	if tmplErr != nil {
		fatalf("failed to parse template: %s", tmplErr)
	}
	for _, service := range services {
		if status, statusErr := service.Status(); statusErr != nil {
			fatalf("status failed: %s", statusErr)
		} else if diagnostics, diagnosticsErr := service.Diagnostics(); diagnosticsErr != nil {
			fatalf("failed to get diagnostics: %s", diagnosticsErr)
		} else {
			if !flagAll && *status.Type == svclib_proto.Service_TASK {
				continue
			}
			if flagRequiresRestartOnly && !*status.NeedsRestart {
				continue
			}
			if err := tmpl.Execute(tabWriter, TemplateValues{
				Name:         service.Name(),
				Owner:        status.GetOwner(),
				Status:       strings.ToLower(status.GetStatusCode().String()),
				Pid:          status.GetPid(),
				CPUTime:      fmtDuration(time.Duration(diagnostics.GetCpuTimeMs() * 1000)),
				NeedsRestart: *status.NeedsRestart,
				RssMb:        fmtBytes(diagnostics.GetRssMb()),
			}); err != nil {
				fatalf("status failed: %s", err)
			}
			fmt.Fprintf(tabWriter, "\n")
		}
	}
	// tabwriter requires an extra flush
	if flushErr := tabWriter.Flush(); flushErr != nil {
		fatalf("Error flushing output. %s", flushErr)
	}
}

func cmdAutoRestart(args []string) {
	flags := newFlagSet("autorestart")
	flags.ParseOrDie(args)
	services, listErr := svclib.ListServices()
	if listErr != nil {
		fatalf("autorestart failed: %s", listErr)
	}
	if len(services) == 0 {
		fmt.Println("No services need to restart.")
		return
	}
	toRestart := []svclib.Service{}
	for _, service := range services {
		if status, runningErr := service.Status(); runningErr != nil {
			fatalf("autorestart failed: %s. %s", service.Name(), runningErr)
		} else {
			if *status.NeedsRestart {
				toRestart = append(toRestart, service)
			}
		}
	}
	// stop and start in parallel, but do all the stops first followed by all the starts.
	// stopping a dependent service can cause a health check to fail, so we need to avoid
	// stopping while waiting for health checks.
	wg := &sync.WaitGroup{}
	for idx := range toRestart {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			service := toRestart[idx]
			if err := service.Stop(); err != nil {
				fatalf("restart failed: %s. %s", service.Name(), err)
			}
		}(idx)
	}
	wg.Wait()
	wg = &sync.WaitGroup{}
	for idx := range toRestart {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			service := toRestart[idx]
			if err := service.Start(); err != nil {
				fatalf("restart failed: %s. %s", service.Name(), err)
			}
			fmt.Printf("restart successful: %s\n", service.Name())
		}(idx)
	}
	wg.Wait()
}

func cmdStop(args []string) {
	flags := newFlagSet("stop")
	flags.ParseOrDie(args)

	for _, name := range flags.Args() {
		s, sErr := svclib.GetService(name)
		if sErr != nil {
			fatalf("stop failed: %s", sErr)
		}
		if err := s.Stop(); err != nil {
			fatalf("stop failed: %s", err)
		}
		fmt.Printf("stop successful: %s\n", name)
	}
}

func cmdStopAll(args []string) {
	flags := newFlagSet("stop-all")
	flags.ParseOrDie(args)
	if err := svclib.StopAll(); err != nil {
		fatalf("stop failed: %s", err)
	}
	fmt.Printf("stop all successful\n")
}

func cmdVersionCheck(args []string) {
	// actual check happens unconditionally, before any function is called
	// this function never gets called if the version check failed, as the program would
	// exit 1 in that case.
	fmt.Printf("Service definitions are up to date.\n")
}

func fmtDuration(d time.Duration) string {
	u := uint64(d)
	neg := d < 0
	if neg {
		u = -u
	}

	msecs := (u / 1e6) % 1000
	secs := (u / 1e9)
	str := fmt.Sprintf("%d.%03ds", secs, msecs)
	if neg {
		return "-" + str
	}

	return str
}

// stolen from go/src/dropbox/ffs/tools/ffs/humanize.go
func fmtBytes(realSize int64) string {
	if realSize < 1024 {
		// If less than "1K", print the number as is.
		return strconv.FormatInt(realSize, 10)
	}

	suffixes := []string{"", "K", "M", "G", "T", "P", "E", "Z", "Y"}
	suffixIndex := 0

	size := float64(realSize)

	for suffixIndex < len(suffixes)-1 {
		if size < 10 {
			return fmt.Sprintf("%.1f%s", size, suffixes[suffixIndex])
		}

		if size < 1024 {
			return fmt.Sprintf("%.0f%s", size, suffixes[suffixIndex])
		}

		size /= 1024
		suffixIndex++
	}

	return fmt.Sprintf("%.0f%s", size, suffixes[suffixIndex])
}
