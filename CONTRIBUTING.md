# Contributing

Contributions are welcome, particularly measured improvements to DSP
throughput, receiver compatibility, mobile interaction, and session storage.

## Development setup

Install the system packages listed in the README, then run:

```bash
make test
make self-test
```

The unit suite uses temporary localhost HTTP servers. The DSP self-test creates
and caches a large synthetic IQ file under `work/`; generated IQ, recordings,
and sessions must not be committed.

## Changes

- Keep RF sample rates, channel spacing, and audio rates explicit.
- Add a regression test for behavioral changes.
- Run `make test` for all changes and `make self-test` for DSP changes.
- Include before/after realtime factors for performance changes using
  `make benchmark` on the same machine.
- Preserve compatibility with saved session metadata when changing storage.
- Do not include recordings of third parties or other captured RF data in pull
  requests.

Use focused commits and describe the receiver hardware and GNU Radio version
when reporting hardware-specific behavior.
