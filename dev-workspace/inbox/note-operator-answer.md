Operator decision on your open proposal (switching mix.exs from the
../oban_claude path dep to hex ~> 0.4): REJECTED, with thanks -- good catch
noticing the 0.4.0 release. The path dep is deliberate ecosystem convention:
local apps track sibling checkouts so in-flight library changes are picked up
immediately; hex pins are for published consumers. The mix.exs comment
documents this. Worth remembering so you don't re-propose it.
