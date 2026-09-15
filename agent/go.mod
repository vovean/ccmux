module ccmuxagent

go 1.23

replace ccmuxd => ../server

require (
	ccmuxd v0.0.0-00010101000000-000000000000
	github.com/goccy/go-yaml v1.19.2
)
