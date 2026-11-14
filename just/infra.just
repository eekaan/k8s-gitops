# Format-check, validate and tofu test every OpenTofu stack, without credentials or a state backend
infra-check: tools-check
    scripts/infra-check

# Plan a stack such as sto2/plumbing; prints counts per action and resource type, never the plan
infra-plan stack:
    scripts/infra-plan {{ quote(stack) }}

# Plan a stack such as sto2/plumbing, print the plan's summary, and apply that plan once the stack's name is typed back (--yes: without asking)
[positional-arguments]
infra-apply stack *flags:
    scripts/infra-apply "$@"

# Print one non-sensitive output of a stack, such as: just infra-output sto2/plumbing talos_version
infra-output stack name:
    scripts/infra-output {{ quote(stack) }} {{ quote(name) }}

# Destroy the cluster stack, then the plumbing stack, each once its name is typed back (--yes: without asking)
[positional-arguments]
infra-destroy *flags:
    scripts/infra-destroy "$@"

# Check the OpenStack credential, quota, flavors and external network; pass or FAIL per item, no figures
os-smoke:
    scripts/os-smoke
