package codexmcphealth

import "time"

// SetDeadline bounds an external protocol driver's complete send/receive phase.
func (c *Connection) SetDeadline(deadline time.Time) error { return c.sock.SetDeadline(deadline) }
