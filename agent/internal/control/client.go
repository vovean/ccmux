package control

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"time"
)

// Send runs one request against the agent. One exchange per connection: a shim that
// crashes mid-launch leaves nothing behind for the next one to trip over.
func Send(socket string, request Request) (Response, error) {
	conn, err := net.DialTimeout("unix", socket, 5*time.Second)
	if err != nil {
		return Response{}, fmt.Errorf("the ccmux agent is not listening on %s "+
			"(systemctl status ccmux-agent): %w", socket, err)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(exchangeTimeout))

	encoded, err := json.Marshal(request)
	if err != nil {
		return Response{}, err
	}
	if _, err := conn.Write(append(encoded, '\n')); err != nil {
		return Response{}, err
	}
	line, err := bufio.NewReaderSize(conn, 1<<20).ReadBytes('\n')
	if err != nil && len(line) == 0 {
		return Response{}, fmt.Errorf("the agent closed the connection without answering")
	}
	var response Response
	if err := json.Unmarshal(line, &response); err != nil {
		return Response{}, fmt.Errorf("could not read the agent's answer: %w", err)
	}
	return response, nil
}

// dial is the test seam for sending something the encoder would never produce.
func dial(socket string) (net.Conn, error) {
	return net.DialTimeout("unix", socket, 5*time.Second)
}
