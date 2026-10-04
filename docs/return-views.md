# Current outputs and historical context

Open `/subjects` or follow Outputs from an agent conversation. Configured roots
use `subject_context` authority, including external uncommitted edits. The shared
`return_context` tool lists current outputs, opens detail, reads historical tool
receipts and records revision-bound line comments. Opening does not launch work.

Production receipts are historical and can survive helper cleanup. They do not
establish document acceptance, live repository state or provider delivery. Current
root and path grants still apply to historical reads. Private tool payloads belong
to the authenticated requesting actor or the human, not every peer with a root grant.

Only subject document reads made through the HTTP MCP endpoint currently create
context receipts. A receipt freezes the exact JSON tool text, content hash and
working revision before response preparation. A matching completed JSON send marks
`server_emitted`. A chunked response, interrupted send or missed persistence stays
`prepared`, not falsely delivered. Client receipt and model use remain unknown.
Standing native instruction layers, provider-hidden context and exact run/session
binding are unavailable on this seam. An observed execution snapshot is not that
binding. Direct shared-operation calls do not fabricate HTTP delivery receipts.

Payloads are retained for seven days and at most 100 payloads per actor. Later
preparation retires excess payloads. Reads label expired payloads explicitly and
never replace them with current file bytes. Metadata remains for audit. Old payloads
may contain private documents, under the same database protections as notebook data.

Feedback binds the observed working revision and inclusive line span. It refuses a
changed revision and requires reread/reanchor. A concurrent external edit after
that read may make the retained comment historical; the comment never alters source
bytes. Feedback is not repository approval or automatic proposal apply.

Remaining #785 scope: proven native instruction/handoff delivery and run binding,
span/hunk review refinements and richer owner/plan navigation. This first slice
keeps unavailable evidence explicit. Pull, migrate and restart to install it.
