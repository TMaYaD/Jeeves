# Vault pages keep their field clocks in one end block

Each page in a Vault carries the clocks that order its fields in one machine-written block at the end of the page, inside an HTML comment. The clocks are not a frontmatter key and not a sidecar file. A deleted Outcome is marked with a `deleted` date in the frontmatter, and its page stays in the Vault.

The clocks must live in the same file as the content they stamp. A file syncer moves files one at a time; with a sidecar, a device holding a page whose clocks have not arrived must either stamp it now, which lets a stale copy outrank a deletion and bring a deleted Outcome back, or wait, which means a page edited by hand in another tool never gets clocks and never appears. A single block at the end keeps the readable part of the page clean: rendered Markdown hides it, and a plain-text editor shows one block at the bottom instead of machine data above the first line of content.

This fixes a format on users' disks, so it is hard to change once pages exist.
