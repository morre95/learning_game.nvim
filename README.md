# LearningGame

LearningGame is a small Neovim mini-game built for LazyVim users who want to drill core motions such as delete, change, yank, undo, and paste. Each session generates a scratch buffer filled with randomly placed assignments that you must travel to and solve. Twenty assignments are created per round, and each assignment is represented by an actual character inside the buffer:

- `x` – delete the marker with `x`
- `r` – replace the character via `r`
- `y` – yank the whole line (for example with `yy`)
- `u` – make a change and undo it with `u`
- `p` – paste your last yank starting on the marker

The game tracks elapsed time, total key presses, and keys per minute. When you complete all assignments you get a centered popup with the run’s stats (aborting still shows a notify-only summary).

## Installation (LazyVim / lazy.nvim)

Add the plugin to your LazyVim configuration and call `setup` once with any overrides you need:

```lua
{
  "erikm/LearningGame",
  config = function()
    require("learning_game").setup({
      assignment_count = 20,
      board = { width = 60, height = 20 },
    })
  end,
}
```

> Replace `erikm/LearningGame` with the actual path to this repository.

Once installed you get two commands:

- `:LearningGameStart` – spawn a new LearningGame tab and begin tracking stats
- `:LearningGameStop` – abort the active session (useful if you want to reset quickly)

## Gameplay Notes

- The buffer is scratch (`nofile`) so you can edit freely without touching existing files.
- Each marker highlights itself until you complete the corresponding action; completed markers disappear and the target prompt jumps to the next assignment.
- Use normal motions to travel quickly between markers. Insertions or deletions will naturally move the remaining markers because they are real buffer characters.
- `p` assignments rely on the text you most recently yanked (from any buffer). Yank first, then paste over the marker.
- Stats are shown via `vim.notify` when the run ends. Closing the buffer early also stops tracking and reports partial progress.

Have fun sharpening those motions!
