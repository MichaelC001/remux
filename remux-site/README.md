# Remux Site

The production website for Remux, served at `getremux.app`.

## Product story

The site follows five sections: home, workspace, preview, controls, and get. It introduces Remux as
an iPhone interface for tmux, then shows how people navigate sessions, preview terminal links, use
terminal controls that a phone keyboard omits, and join the public beta.

## Design constraints

- use tmux and terminal UI as a quiet layout grammar, not decoration;
- use the production app icon and its green-black, soft-teal, and live-amber palette;
- use proportional type for product messaging and monospace for labels, controls, and status;
- cap the desktop content frame at 1320 pixels, with a media-led 42/58 feature split;
- size headings from their copy container so reversed layouts retain the same hierarchy;
- cap desktop feature content at 720 pixels high and leave clear space around the full device;
- use 24-pixel gutters between desktop sections and 16-pixel gutters between mobile sections;
- use the same copy inset for hero and feature panes while preserving their type hierarchy;
- keep feature detail to three compact, concrete rows with no numbering or card treatment;
- let sections scroll naturally on mobile instead of shrinking an entire section into one viewport;
- show one dominant visual or interaction per section and avoid nested decorative chrome;
- keep view switching in the section bar instead of nesting a second tab bar inside the media pane;
- preserve device geometry and size phones from the media pane height, not from viewport width;
- use the official iPhone Air frame for the document Preview composition;
- let the current product walkthrough fill the home media pane, with a still for reduced motion;
- keep the desktop tmux status line as secondary navigation and make it non-fixed on mobile;
- point TestFlight actions to the public invite at <https://testflight.apple.com/join/fHqG1ruE>.

## Preview

```bash
python3 -m http.server 4175 --bind 127.0.0.1 --directory remux-site
```

Then open <http://127.0.0.1:4175/>.
