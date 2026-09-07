# Rules

## Check what the other side is actually listening for before fixing your own code

Uberkey emitted ⌃⌥⇧⌘ because that is what "hyper key" conventionally means, and Alfred
never fired. Every visible sign pointed at our own machinery — so two rounds of work went
into how modifiers get delivered, on the theory that a flag stamped onto a key event is
not the same as a modifier genuinely held down. That theory is true and the resulting code
is correct, but it was not the bug. The bug was that Alfred's saved hotkey is
`mod => 1835008`, which is control+option+command with no shift, and Hyperkey's config is
the identical value, and so is TypeWhisper's — every hyper binding on this machine expects
three modifiers, not four. Sending a fourth made it a different chord that matched nothing.
The tell was there the whole time and was misread as reassuring: our own log showed
`hyper down` and `stamping hyper flags` on every press, meaning our code ran perfectly. When
your side reports success and the other side does nothing, the mismatch is in what the two
sides have agreed on, not in how your side works. Go and read the other side's actual
configuration — a hotkey's stored modifier mask, a port number, a field name — before
theorising about mechanism. It is usually one cheap file read away, and here it was the
whole answer.
