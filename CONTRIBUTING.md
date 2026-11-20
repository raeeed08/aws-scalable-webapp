# Contributing

Thank you for your interest in improving this project. Bug reports, ideas and pull requests are welcome.

## Reporting bugs and asking questions

Open an [issue](../../issues/new/choose) and pick the matching template. For a bug, include what you ran,
what you expected, what happened, and the output of `terraform version`. Never paste secrets, AWS account ids
or `terraform.tfvars` values.

## Pull requests

1. Fork the repository and create a branch from `main`.
2. Keep each pull request focused on one change.
3. Before pushing, run the same checks as the CI:

   ```bash
   cd deployment/terraform
   terraform fmt -recursive
   terraform init -backend=false
   terraform validate
   checkov -d . --framework terraform   # any new skip needs a #checkov:skip=ID:reason comment
   shellcheck ../scripts/*.sh
   ```

4. Update `README.md` and `CHANGELOG.md` when behaviour or inputs change.
5. Open the pull request and fill in the template.

## Security issues

Do not open a public issue for a security problem. See [SECURITY.md](SECURITY.md).

## License

By contributing, you agree that your contributions are licensed under the [Apache License 2.0](LICENSE).
