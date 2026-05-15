# Global Configuration

In this directory is the machine-level override. Anything written here
applies to every study run on this installation, regardless of project.

This is the right place for settings that reflect the environment: which
remote server handles taxonomy assignment, how many threads this machine
can spare, as well as primers available to be picked by cutadapt. If you
are a contributor, your configurations here will not be committed.

Leave a key out entirely to inherit the default. Only write what you
deliberately want to change.

Note that this is the lowest-precedence level after the defaults. Any
setting written here can be overridden at the project, group, or run
level; this simply serves as the fallback for every run that does not
explicitly override it.
