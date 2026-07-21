package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net"
	"os"
	"os/signal"
	"runtime"
	"syscall"
	"time"

	"github.com/sagernet/sing-box/daemon"
	"github.com/sagernet/sing-box/include"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/emptypb"
)

var (
	version   = "unknown"
	buildTags = "unknown"
)

type platformHandler struct {
	service    *daemon.StartedService
	configPath string
	stopped    chan struct{}
}

func (h *platformHandler) ServiceStop() error {
	if err := h.service.CloseService(); err != nil {
		return err
	}
	select {
	case <-h.stopped:
	default:
		close(h.stopped)
	}
	return nil
}

func (h *platformHandler) ServiceReload() error {
	content, err := os.ReadFile(h.configPath)
	if err != nil {
		return err
	}
	return h.service.StartOrReloadService(string(content), nil)
}

func (*platformHandler) SystemProxyStatus() (*daemon.SystemProxyStatus, error) {
	return &daemon.SystemProxyStatus{Available: false}, nil
}

func (*platformHandler) SetSystemProxyEnabled(bool) error {
	return status.Error(codes.Unimplemented, "system proxy is managed by NekoPilot")
}

func (*platformHandler) TriggerNativeCrash() error {
	return status.Error(codes.Unimplemented, "native crash is disabled")
}

func (*platformHandler) WriteDebugMessage(message string) { fmt.Fprintln(os.Stderr, message) }
func (*platformHandler) ConnectSSHAgent() (int32, error) {
	return -1, status.Error(codes.Unimplemented, "SSH agent is unavailable")
}

func main() {
	if len(os.Args) < 2 {
		fatal(errors.New("expected run, check, or version"))
	}
	switch os.Args[1] {
	case "version":
		fmt.Printf("sing-box version %s\n\nEnvironment: %s %s/%s\nTags: %s\nRevision: unknown\nCGO: enabled\n", version, runtime.Version(), runtime.GOOS, runtime.GOARCH, buildTags)
	case "check":
		check(os.Args[2:])
	case "run":
		run(os.Args[2:])
	case "ctl":
		control(os.Args[2:])
	default:
		fatal(fmt.Errorf("unknown command %q", os.Args[1]))
	}
}

func control(arguments []string) {
	flags := flag.NewFlagSet("ctl", flag.ContinueOnError)
	socketPath := flags.String("api-socket", "", "native gRPC Unix socket")
	groupTag := flags.String("group", "ExitGateway", "outbound group")
	nodeTag := flags.String("node", "", "outbound node")
	if err := flags.Parse(arguments); err != nil {
		fatal(err)
	}
	if *socketPath == "" || flags.NArg() != 1 {
		fatal(errors.New("usage: ctl --api-socket PATH <ready|reload|groups|outbounds|url-test|select>"))
	}
	connection, client, err := dialControl(*socketPath)
	if err != nil {
		fatal(err)
	}
	defer connection.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	switch flags.Arg(0) {
	case "ready":
		stream, callErr := client.SubscribeServiceStatus(ctx, &emptypb.Empty{})
		if callErr != nil { fatal(callErr) }
		message, callErr := stream.Recv()
		if callErr != nil || message.Status != daemon.ServiceStatus_STARTED { fatal(firstError(callErr, errors.New(message.ErrorMessage))) }
		writeJSON(map[string]bool{"ready": true})
	case "reload":
		_, callErr := client.ReloadService(ctx, &emptypb.Empty{})
		if callErr != nil { fatal(callErr) }
		writeJSON(map[string]bool{"reloaded": true})
	case "groups":
		stream, callErr := client.SubscribeGroups(ctx, &emptypb.Empty{})
		if callErr != nil { fatal(callErr) }
		message, callErr := stream.Recv()
		if callErr != nil { fatal(callErr) }
		writeJSON(message)
	case "outbounds":
		stream, callErr := client.SubscribeOutbounds(ctx, &emptypb.Empty{})
		if callErr != nil { fatal(callErr) }
		message, callErr := stream.Recv()
		if callErr != nil { fatal(callErr) }
		writeJSON(message)
	case "url-test":
		if *groupTag == "" { fatal(errors.New("group is required")) }
		_, callErr := client.URLTest(ctx, &daemon.URLTestRequest{OutboundTag: *groupTag})
		if callErr != nil { fatal(callErr) }
		writeJSON(map[string]bool{"accepted": true})
	case "select":
		if *groupTag == "" || *nodeTag == "" { fatal(errors.New("group and node are required")) }
		_, callErr := client.SelectOutbound(ctx, &daemon.SelectOutboundRequest{GroupTag: *groupTag, OutboundTag: *nodeTag})
		if callErr != nil { fatal(callErr) }
		writeJSON(map[string]bool{"selected": true})
	default:
		fatal(fmt.Errorf("unknown control command %q", flags.Arg(0)))
	}
}

func dialControl(socketPath string) (*grpc.ClientConn, daemon.StartedServiceClient, error) {
	dialer := func(ctx context.Context, _ string) (net.Conn, error) {
		return new(net.Dialer).DialContext(ctx, "unix", socketPath)
	}
	connection, err := grpc.NewClient("passthrough:///nekopilot", grpc.WithTransportCredentials(insecure.NewCredentials()), grpc.WithContextDialer(dialer))
	if err != nil { return nil, nil, err }
	return connection, daemon.NewStartedServiceClient(connection), nil
}

func firstError(first, fallback error) error {
	if first != nil { return first }
	if fallback != nil && fallback.Error() != "" { return fallback }
	return errors.New("service is not ready")
}

func writeJSON(value any) {
	if err := json.NewEncoder(os.Stdout).Encode(value); err != nil { fatal(err) }
}

func configFlags(name string, arguments []string) (string, string) {
	flags := flag.NewFlagSet(name, flag.ContinueOnError)
	configPath := flags.String("c", "", "configuration path")
	socketPath := flags.String("api-socket", "", "native gRPC Unix socket")
	flags.Bool("disable-color", false, "disable colored logs")
	if err := flags.Parse(arguments); err != nil {
		fatal(err)
	}
	if *configPath == "" {
		fatal(errors.New("configuration path is required"))
	}
	return *configPath, *socketPath
}

func check(arguments []string) {
	configPath, _ := configFlags("check", arguments)
	content, err := os.ReadFile(configPath)
	if err != nil {
		fatal(err)
	}
	ctx, cancel := context.WithCancel(include.Context(context.Background()))
	defer cancel()
	service := daemon.NewStartedService(daemon.ServiceOptions{Context: ctx})
	defer service.Close()
	if err = service.CheckConfig(string(content)); err != nil {
		fatal(err)
	}
}

func run(arguments []string) {
	configPath, socketPath := configFlags("run", arguments)
	if socketPath == "" {
		fatal(errors.New("native gRPC socket path is required"))
	}
	content, err := os.ReadFile(configPath)
	if err != nil {
		fatal(err)
	}
	if err = os.Remove(socketPath); err != nil && !errors.Is(err, os.ErrNotExist) {
		fatal(err)
	}
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		fatal(err)
	}
	defer func() {
		listener.Close()
		os.Remove(socketPath)
	}()
	if err = os.Chmod(socketPath, 0o600); err != nil {
		fatal(err)
	}

	ctx, cancel := context.WithCancel(include.Context(context.Background()))
	defer cancel()
	handler := &platformHandler{configPath: configPath, stopped: make(chan struct{})}
	service := daemon.NewStartedService(daemon.ServiceOptions{
		Context:     ctx,
		Handler:     handler,
		LogMaxLines: 1000,
	})
	handler.service = service
	defer service.Close()

	server := grpc.NewServer()
	daemon.RegisterStartedServiceServer(server, service)
	go func() {
		if serveErr := server.Serve(listener); serveErr != nil && !errors.Is(serveErr, grpc.ErrServerStopped) {
			fmt.Fprintln(os.Stderr, serveErr)
			select {
			case <-handler.stopped:
			default:
				close(handler.stopped)
			}
		}
	}()
	defer server.GracefulStop()

	if err = service.StartOrReloadService(string(content), nil); err != nil {
		fatal(err)
	}
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, os.Interrupt, syscall.SIGTERM)
	defer signal.Stop(signals)
	for {
		select {
		case <-signals:
			_ = service.CloseService()
			return
		case <-handler.stopped:
			return
		}
	}
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}
