package daemon

// ancestorClaudeFromArgv decides whether one ancestor is Claude from its command
// name. Arguments are read only for an interpreter, which may host the harness
// (node running cli.js, for example). An interpreter whose arguments cannot be
// read is refused, never skipped: a desktop Claude further up the chain must not
// become the actor for it.
func ancestorClaudeFromArgv(command string, arguments func() (string, error)) (bool, error) {
	if classifyAgentProcess(command, "") == "claude" {
		return true, nil
	}
	if !harnessInterpreter(command) {
		return false, nil
	}
	args, err := arguments()
	if err != nil {
		return false, err
	}
	return classifyAgentProcess(command, args) == "claude", nil
}
