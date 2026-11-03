# Publishing this kit on GitHub — step by step

> A guide to putting this local repository online under your GitHub account
> (example with the `Luclegay` account — replace it with yours). Every command
> is explained.

## Step 1 — Check the local state

```bash
cd ~/Desktop/claude-memory-kit
git status
```
`git status` shows the state of the repository. You should see "nothing to commit,
working tree clean" (everything is already saved). If files show up in red:

```bash
git add -A                                  # "stage all files"
git commit -m "Tweaks before publishing"    # "save with this message"
```

## Step 2 — Create the repository on GitHub (web interface, the simplest way)

1. Go to https://github.com/new (signed in to your account).
2. **Repository name**: `claude-memory-kit`
3. **Description**: `File-based memory + learning from mistakes + Dreaming for Claude Code (based on Lamis Mukta's talk, Anthropic)`
4. Choose **Public**.
5. ⚠️ Do NOT tick ANY box ("Add a README", "Add .gitignore", "license"):
   the local repository already contains them — ticking them would create conflicts.
6. Click **Create repository**.

## Step 3 — Link the local repository to GitHub and push

GitHub then shows an instructions page. The section that concerns us is
"…or push an existing repository from the command line":

```bash
cd ~/Desktop/claude-memory-kit
git remote add origin https://github.com/Luclegay/claude-memory-kit.git
git branch -M main
git push -u origin main
```

What each line does:
- `git remote add origin <url>`: "the online repository is called *origin* and
  lives at this address";
- `git branch -M main`: renames the current branch to `main` (the standard);
- `git push -u origin main`: sends everything to GitHub and remembers the link
  (future pushes will be a simple `git push`).

If the Terminal asks for a password: GitHub no longer accepts passwords,
you need an **access token** (Settings → Developer settings → Personal access
tokens → *Generate new token (classic)*, tick `repo`) to paste instead of the
password. A more comfortable alternative: install the official tool
`brew install gh` then run `gh auth login`, and authentication is handled for you.

## Step 4 — Verify

Open https://github.com/Luclegay/claude-memory-kit: the README shows up as
the home page, with the diagram. It's live! 🎉

## For future updates

```bash
cd ~/Desktop/claude-memory-kit
git add -A
git commit -m "Short description of the change"
git push
```
