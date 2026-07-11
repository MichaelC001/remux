# Remux Site

The production website for Remux, served at `getremux.app`.

## Design constraints

- every content section is one viewport-high tmux window;
- the fixed tmux status line is the primary section navigation;
- screenshots live inside flat, bordered panes;
- no sticky story, oversized section padding, decorative glow, or rotated phones;
- TestFlight actions use a replaceable placeholder URL until the final invite is issued.

## Preview

```bash
python3 -m http.server 4175 --bind 127.0.0.1 --directory remux-site
```

Then open <http://127.0.0.1:4175/>.
