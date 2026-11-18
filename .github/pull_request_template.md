## Summary

<!-- What changed and why, in a paragraph. Cite plan IDs (L4, SL1). -->

## What's affected

<!-- Modules, packages or services touched; docs/architecture sections updated; contract (proto) changes. -->

## Tests

<!-- Which tiers ran (unit, integration, policy, e2e) and the local gate result. -->

## Security

<!-- What crosses a trust boundary, what is logged, any new secret or permission. -->

- [ ] Touches tenant isolation or audit evidence (RLS, tenantdb, blobstore, authn, logging scrub, custody, purge)
- [ ] No secrets, tokens or client data in the diff
