# IAM Actions CLI

Small Bash script to get AWS IAM service Actions.

IAM Actions are the permissions that can be attached to IAM policies.

Unfortunately there is currently no way to obtain a list of these without having
to switch to a browser. This CLI uses the official AWS
[service-list.json](https://servicereference.us-east-1.amazonaws.com/v1/service-list.json)
to interactively obtain IAM Actions.

## Usage

![](./docs/usage.gif)

```bash
bash iam-actions.sh
```

To list all available options:
```bash
bash iam-actions --help
```
