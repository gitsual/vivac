# Portable automations

Machine-specific services are represented as data, not copied with private endpoints, paths or identities.

## Generic task service

The `automation` Stow package installs:

- `workstation-task-runner`, a Python executor that accepts a JSON argument array without invoking a shell;
- `workstation-task@.service`, a restart-on-failure user-service template;
- `workstation-task@.timer`, a persistent weekly timer template with randomized delay.

Create a destination-local task from the public example:

```bash
mkdir -p ~/.config/workstation/tasks
cp profiles/automation/example.json ~/.config/workstation/tasks/example.json
systemctl --user daemon-reload
task_name=example
systemctl --user start "workstation-task@${task_name}.service"
```

For a recurring task:

```bash
systemctl --user enable --now "workstation-task@${task_name}.timer"
```

A task description contains an argument array, working directory and optional environment mapping. Tokens and machine-bound endpoints should come from a private environment loader or credential manager; they must not be committed in the JSON file. Use a unit drop-in when a task needs a different schedule, additional sandboxing or explicit writable-path restrictions.

This mechanism can represent local servers, synchronization commands, watchdogs, maintenance utilities and other user processes while keeping their private parameters outside the public repository.
