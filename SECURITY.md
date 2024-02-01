# Security Policy

No technology is perfect, and Homebrew believes that working with skilled security researchers across the globe is crucial in identifying weaknesses in any technology. If you believe you've found a security issue in Homebrew, we encourage you to notify us. We welcome working with you to resolve the issue promptly. Thank you for keeping Homebrew and its users safe!

## Disclosure Policy

Let us know as soon as possible upon discovery of a potential security issue, and we'll make every effort to quickly resolve the issue. Please bear in mind we're a project run entirely by volunteers in our spare time.

Make a good faith effort to avoid privacy violations, destruction of data, and interruption or degradation of our service. Only interact with accounts you own or with our explicit permission.

See the ["Security" section of our README](https://github.com/Homebrew/brew/blob/master/README.md#security) for instructions on how to report a security vulnerability.

If it's a straightforward fix: please submit a pull request on GitHub.

We will respond to and fix reported, reproducible security vulnerabilities as soon as possible. A gentle reminder that we are a volunteer-run project so please cut us some slack here. Provide us a reasonable amount of time to resolve the issue before any disclosure to the public or a third-party.

## Supported Versions

Homebrew is a rolling release package manager. This means:

- only the latest release and latest commit on the `master` branch of Homebrew/brew are supported.
- only the latest commit on the `master` branch of all Homebrew repositories is supported.

## Scope

The following sites and applications are within scope for this program:

- The brew package manager (Homebrew/brew)
- The Homebrew/homebrew-* official taps

## Exclusions

The following do not constitute security vulnerabilities in Homebrew:

- brew.sh websites
- brew.sh domain SPF configuration
- security vulnerabilities in hosted web services Homebrew relies on (e.g. GitHub, Google Analytics, GitHub Pages)
- security vulnerabilities in packaged software that are present in the upstream software (although these should be reported to the upstream software)
- security vulnerabilities in software used by but not written by Homebrew
- nominal clickjacking and similar attacks against our static, GitHub Pages websites

## Conduct

While researching, we ask you to refrain from:

- Denial of service
- Spamming
- Social engineering (including phishing) of Homebrew maintainers or contributors
- Any physical attempts against Homebrew's machines
- Performing vulnerability research in public, such as testing discoveries by opening pull requests to Homebrew's public repositories without prior written approval
