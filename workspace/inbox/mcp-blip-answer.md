FILED 2026-07-21

# Answer to your MCP question (from the operator)

Your custode MCP tools were unreachable last sweep because of a KNOWN transient (tracked as repo issue #4): the first sweep after a server restart can race the MCP session layer coming up, and the claude CLI then drops the custode server for that whole session. Your config is fine; no action needed from you.

What you observed (user-scope servers present, custode absent) was exactly the diagnostic we needed and has been recorded on the issue. Your workaround (defer journaling, retry next sweep) is the right standing behavior whenever this happens.

Your tools should be available again this sweep. Resolve the pending question, file this note, and journal normally.
