# Making your first change

Clone the repository and follow the README to run the app in an iPhone simulator.
Choose one small change you want to use, such as clearer wording or a layout
adjustment. Start your AI coding tool in this repository so it reads AGENTS.md.

A useful first prompt:

> Read AGENTS.md and README.md. Pull the latest main if the working tree is
> clean. I want to [describe the improvement]. Implement it, check both English
> and German where relevant, run the appropriate checks, and show me how to try
> it in the simulator. Keep the work on main. Do not push or install on a real
> phone until I ask.

Try the result yourself. When satisfied, ask the tool to review the staged files
for accidental personal data, commit the change, pull/rebase the latest main,
rerun affected checks if necessary, and push to main. If a conflict is unclear,
coordinate with the other contributor before resolving it.

Use your own GitHub account. Ask the repository owner to invite that account;
being able to view a public repository does not grant commit access. You do not
need another person's Apple account to build and use the simulator.

For a physical-phone update, agree on the change, back up the existing history,
and handle signing and private service configuration separately. Keep those
materials off GitHub. A successful push does not deploy or install the app.
