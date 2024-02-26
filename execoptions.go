package rig

import (
	"bytes"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"os"
	"regexp"
	"strings"

	"github.com/k0sproject/rig/log"
	"github.com/k0sproject/rig/powershell"
)

// RedactMask is the string that will be used to replace redacted text in the logs.
const DefaultRedactMask = "[REDACTED]"

// Option is a functional option for the exec package.
type ExecOption func(*ExecOptions)

// RedactFunc is a function that takes a string and returns a redacted string.
type RedactFunc func(string) string

// DecorateFunc is a function that takes a string and returns a decorated string.
type DecorateFunc func(string) string

// Options is a collection of exec options.
type ExecOptions struct {
	log.LoggerInjectable

	in     io.Reader
	out    io.Writer
	errOut io.Writer

	allowWinStderr bool

	logInfo    bool
	logDebug   bool
	logError   bool
	logCommand bool
	logOutput  bool
	logInput   bool

	streamOutput bool
	trimOutput   bool

	wroteErr bool

	redactFuncs   []RedactFunc
	decorateFuncs []DecorateFunc
}

func decodeEncoded(cmd string) string {
	if !strings.Contains(cmd, "powershell") {
		return cmd
	}

	parts := strings.Split(cmd, " ")
	for i, p := range parts {
		if p == "-E" || p == "-EncodedCommand" && len(parts) > i+1 {
			decoded, err := base64.StdEncoding.DecodeString(parts[i+1])
			if err == nil {
				parts[i+1] = strings.ReplaceAll(string(decoded), "\x00", "")
			}
		}
	}
	return strings.Join(parts, " ")
}

// Command returns the command string with all decorators applied.
func (o *ExecOptions) Command(cmd string) string {
	for _, decorator := range o.decorateFuncs {
		cmd = decorator(cmd)
	}
	return cmd
}

// AllowWinStderr returns the allowWinStderr option.
func (o *ExecOptions) AllowWinStderr() bool {
	return o.allowWinStderr
}

// LogCmd is for logging the command to be executed.
func (o *ExecOptions) LogCmd(cmd string) {
	if o.logCommand {
		o.Log().Debugf("executing `%s`", o.Redact(decodeEncoded(cmd)))
	} else {
		o.Log().Debugf("executing command")
	}
}

var (
	errCharDevice    = errors.New("reader is a character device")
	errUnknownReader = errors.New("unknown type of reader")
)

func getReaderSize(reader io.Reader) (int64, error) {
	switch v := reader.(type) {
	case *bytes.Buffer:
		return int64(v.Len()), nil
	case *os.File:
		stat, err := v.Stat()
		if err != nil {
			return 0, fmt.Errorf("failed to stat reader: %w", err)
		}

		if stat.Mode()&os.ModeCharDevice != 0 {
			return 0, errCharDevice
		}

		return stat.Size(), nil
	default:
		return 0, errUnknownReader
	}
}

// Stdin returns the Stdin reader. If input logging is enabled, it will be a TeeReader that writes to the log.
func (o *ExecOptions) Stdin() io.Reader {
	if o.in == nil {
		return nil
	}

	size, err := getReaderSize(o.in)
	if err == nil && size > 0 {
		o.Log().Debugf("using %d bytes of data from reader as command input", size)
	} else {
		o.Log().Debugf("using data from reader as command input")
	}

	if o.logInput {
		return io.TeeReader(o.in, redactingWriter{w: logWriter{fn: o.Log().Debugf}, fn: o.Redact})
	}

	return o.in
}

// Stdout returns the Stdout writer. If output logging is enabled, it will be a MultiWriter that writes to the log.
func (o *ExecOptions) Stdout() io.Writer {
	var writers []io.Writer
	switch {
	case o.streamOutput:
		writers = append(writers, redactingWriter{w: logWriter{fn: o.Log().Infof}, fn: o.Redact})
	case o.logOutput:
		writers = append(writers, redactingWriter{w: logWriter{fn: o.Log().Debugf}, fn: o.Redact})
	}
	if o.out != nil {
		writers = append(writers, o.out)
	}
	return io.MultiWriter(writers...)
}

// Stderr returns the Stderr writer. If error logging is enabled, it will be a MultiWriter that writes to the log.
func (o *ExecOptions) Stderr() io.Writer {
	var writers []io.Writer
	switch {
	case o.streamOutput:
		writers = append(writers, redactingWriter{w: logWriter{fn: o.Log().Errorf}, fn: o.Redact})
	case o.logError:
		writers = append(writers, redactingWriter{w: logWriter{fn: o.Log().Debugf}, fn: o.Redact})
	}
	writers = append(writers, &flaggingWriter{b: &o.wroteErr})
	if o.errOut != nil {
		writers = append(writers, o.errOut)
	}

	return io.MultiWriter(writers...)
}

// WroteErr returns true if the command wrote to stderr.
func (o *ExecOptions) WroteErr() bool {
	return o.wroteErr
}

// AllowWinStderr exec option allows command to output to stderr without failing.
func AllowWinStderr() ExecOption {
	return func(o *ExecOptions) {
		o.allowWinStderr = true
	}
}

// Redact is for filtering out sensitive text using a regexp.
func (o *ExecOptions) Redact(s string) string {
	if DisableRedact || len(o.redactFuncs) == 0 {
		return s
	}
	for _, fn := range o.redactFuncs {
		s = fn(s)
	}
	return s
}

// FormatOutput is for trimming whitespace from the command output if TrimOutput is enabled.
func (o *ExecOptions) FormatOutput(s string) string {
	if o.trimOutput {
		return strings.TrimSpace(s)
	}
	return s
}

// Stdin exec option for sending data to the command through stdin.
func Stdin(r io.Reader) ExecOption {
	return func(o *ExecOptions) {
		o.in = r
	}
}

// StdinString exec option for sending string data to the command through stdin.
func StdinString(s string) ExecOption {
	return func(o *ExecOptions) {
		o.in = strings.NewReader(s)
	}
}

// Stdout exec option for sending command stdout to an io.Writer.
func Stdout(w io.Writer) ExecOption {
	return func(o *ExecOptions) {
		o.out = w
	}
}

// Stderr exec option for sending command stderr to an io.Writer.
func Stderr(w io.Writer) ExecOption {
	return func(o *ExecOptions) {
		o.errOut = w
	}
}

// StreamOutput exec option for sending the command output to info log.
func StreamOutput() ExecOption {
	return func(o *ExecOptions) {
		o.streamOutput = true
	}
}

// LogError exec option for enabling or disabling live error logging during exec.
func LogError(v bool) ExecOption {
	return func(o *ExecOptions) {
		o.logError = v
	}
}

// HideCommand exec option for hiding the command-string and stdin contents from the logs.
func HideCommand() ExecOption {
	return func(o *ExecOptions) {
		o.logCommand = false
	}
}

// HideOutput exec option for hiding the command output from logs.
func HideOutput() ExecOption {
	return func(o *ExecOptions) {
		o.logOutput = false
		o.logError = false
	}
}

// Sensitive exec option for disabling all logging of the command.
func Sensitive() ExecOption {
	return func(o *ExecOptions) {
		o.logDebug = false
		o.logInfo = false
		o.logError = false
		o.logCommand = false
	}
}

// Redact exec option for defining a redact regexp pattern that will be replaced with [REDACTED] in the logs.
func Redact(rexp string) ExecOption {
	return func(o *ExecOptions) {
		re := regexp.MustCompile(rexp)
		o.redactFuncs = append(o.redactFuncs, func(s string) string {
			return re.ReplaceAllString(s, RedactMask)
		})
	}
}

// RedactString exec option for defining one or more strings to replace with [REDACTED] in the log output.
func RedactString(s ...string) ExecOption {
	var newS []string
	for _, str := range s {
		if str != "" {
			newS = append(newS, str)
		}
	}

	return func(o *ExecOptions) {
		o.redactFuncs = append(o.redactFuncs, func(s2 string) string {
			newstr := s2
			for _, r := range newS {
				newstr = strings.ReplaceAll(newstr, r, RedactMask)
			}
			return newstr
		})
	}
}

// LogInput exec option for enabling or disabling live input logging during exec.
func LogInput(v bool) ExecOption {
	return func(o *ExecOptions) {
		o.logInput = v
	}
}

// TrimOutput exec option for controlling if the output of the command will be trimmed of whitespace.
func TrimOutput(v bool) ExecOption {
	return func(o *ExecOptions) {
		o.trimOutput = v
	}
}

// PS exec option for using powershell to execute the command on windows.
func PS() ExecOption {
	return func(o *ExecOptions) {
		o.decorateFuncs = append(o.decorateFuncs, powershell.Cmd)
	}
}

// PSCompressed is like PS but for long command scriptlets. The script will be gzipped
// and base64 encoded and includes a small decompression script at the beginning of the command.
// This can allow running longer scripts than the 8191 characters that powershell.exe allows.
func PSCompressed() ExecOption {
	return func(o *ExecOptions) {
		o.decorateFuncs = append(o.decorateFuncs, powershell.CompressedCmd)
	}
}

// Decorate exec option for applying a custom decorator to the command string.
func Decorate(decorator DecorateFunc) ExecOption {
	return func(o *ExecOptions) {
		o.decorateFuncs = append(o.decorateFuncs, decorator)
	}
}

// Build returns an instance of Options.
func Build(opts ...ExecOption) *ExecOptions {
	options := &ExecOptions{
		logInfo:      false,
		logCommand:   true,
		logDebug:     true,
		logError:     true,
		logOutput:    true,
		logInput:     false,
		streamOutput: false,
		trimOutput:   true,
	}

	options.Apply(opts...)

	return options
}

// Apply the supplied options to the Options.
func (o *ExecOptions) Apply(opts ...ExecOption) {
	for _, opt := range opts {
		opt(o)
	}
}

// a writer that calls a logging function for each line written.
type logWriter struct {
	fn func(...any)
}

// Write writes the given bytes to the log function.
func (l logWriter) Write(p []byte) (int, error) {
	s := string(p)
	l.fn(s)
	return len(p), nil
}

// flaggingWriter is a discarding writer that sets a flag when it writes something, used
// to check if a command has output to stderr.
type flaggingWriter struct {
	b *bool
}

func (f *flaggingWriter) Write(p []byte) (int, error) {
	if !*f.b && len(p) > 0 {
		*f.b = true
	}
	return len(p), nil
}

