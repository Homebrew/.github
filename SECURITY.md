# Security Policy

No technology is perfect, and Homebrew believes that working with skilled security researchers across the globe is crucial in identifying weaknesses in any technology. If you believe you've found a security issue in Homebrew, we encourage you to notify us. We welcome working with you to resolve the issue promptly. Thank you for keeping Homebrew and its users safe!

## Disclosure Policy

Let us know as soon as possible upon discovery of a potential security issue, and we'll make every effort to quickly resolve the issue. Please bear in mind we're a project run entirely by volunteers in our spare time.

Make a good faith effort to avoid privacy violations, destruction of data, and interruption or degradation of our service. Only interact with accounts you own or with our explicit permission.

Please report suspected security vulnerabilities through GitHub's private vulnerability reporting for the affected repository. For Homebrew/brew, use [the security advisory form](https://github.com/Homebrew/brew/security/advisories/new).

If it's a straightforward fix: please submit a pull request on GitHub.

We will respond to and fix reported, reproducible security vulnerabilities as soon as possible. A gentle reminder that we are a volunteer-run project so please cut us some slack here. Provide us a reasonable amount of time to resolve the issue before any disclosure to the public or a third-party.

## Supported Versions

Homebrew is a rolling release package manager. This means:

- only the latest release and latest commit on the `main` (or `master` if not yet migrated to `main`) branch of Homebrew/brew are supported.
- only the latest commit on the `main` (or `master` if not yet migrated to `main`) branch of all Homebrew repositories is supported.

## Threat Model

Homebrew protects the integrity of Homebrew-maintained code, official formula and cask metadata, official bottle metadata, checksum verification, update and install logic, CI and release infrastructure, build sandboxing and credential filtering.

Security issues are defects in Homebrew-maintained code or infrastructure that let an attacker violate those guarantees without already controlling the user's account, local machine, maintainer account, command line, environment, configuration, third-party tap, mirror, wrapper or repository.

Homebrew is designed around a single-user machine security boundary. Homebrew assumes the user running `brew` controls and trusts their own account, Homebrew prefix, cache, configuration, taps and shell environment. Shared multi-user Homebrew installations are unsupported and outside Homebrew's security boundary.

Homebrew necessarily executes third-party software chosen by the user. Formulae and casks may run upstream build systems, installers and post-install commands. External taps, mirrors, wrappers and repositories configured by the user are trusted at the level the user granted them.

Installing from a tap is a trust decision for that tap. A tap can provide formulae, casks, external commands and tap metadata that install or run software, so using a tap means trusting its authors for those files.

Homebrew's boundary for upstream software is the `brew`-managed install, post-install and test execution path. Escapes from Homebrew's intended sandboxing or credential filtering in those phases may be security issues. Once a user runs installed upstream software directly, sandboxing and trusting that software is the user's responsibility.

## In Scope

The following sites and applications are within scope for this program:

- The `brew` package manager (Homebrew/brew)
- The Homebrew/homebrew-core and Homebrew/homebrew-cask official taps
- Homebrew-run infrastructure, including MacStadium workers and Homebrew-operated software running in cloud providers

Examples of in-scope security issues include:

- bypassing Homebrew's checksum or integrity checks for downloaded files
- running attacker-chosen code through Homebrew's trusted update or release paths, or through installation of formulae, casks or external commands from official Homebrew taps
- leaking credentials that Homebrew intentionally filters from builds or subprocesses
- escaping Homebrew's documented build sandbox or permission hardening
- tampering with official Homebrew metadata, bottles, releases or CI outputs
- silently treating an untrusted tap, mirror, wrapper, fork or repository as an official Homebrew source
- escaping Homebrew's intended install, post-install or test sandboxing on supported configurations

## Not Security Issues

The following do not constitute security vulnerabilities in Homebrew:

### Attacker-Supplied Commands, Configuration or Environment

A bug triggered only by convincing a user or CI job to run a crafted `brew` command, pass crafted arguments, set crafted environment variables, edit local configuration or execute an attacker-controlled script is not a security issue. An attacker who can control those inputs can already instruct Homebrew to install or run arbitrary software.

### Third-Party Taps, Mirrors, Wrappers or Repositories

A bug that depends on using an untrusted tap, mirror, wrapper, fork, checkout or repository is not a Homebrew security issue unless Homebrew's own code silently treats it as official or bypasses a documented protection. Users who configure these sources grant them trust outside Homebrew's security boundary, including trust in the tap author's formulae, casks, external commands and tap metadata.

### Malicious or Vulnerable Upstream Software

Malware, unwanted behaviour, vulnerable upstream releases, malicious install scripts, vulnerable casks or dangerous upstream build systems are not Homebrew security issues by themselves. Homebrew packages third-party software selected by users; removal or metadata changes for problematic packages should be handled in public issues or pull requests.

### Antivirus and VirusTotal Detections

Reports based only on third-party scanner output, such as VirusTotal, Intego, ClamAV or other antivirus detections on a Homebrew-installed file, are not Homebrew security issues by themselves. File hashes and scanner result permalinks help identify the sample, but they are not sufficient evidence that it is malware. Reports need independent verification that the file is malicious and that a Homebrew-maintained security boundary was violated. To date, every Homebrew report based only on third-party antivirus detections of installed files has been a false positive. Reports from Apple's built-in macOS malware protection should be filed with Apple. We may also act on such reports if shared with Homebrew, since the signal comes from Apple itself and we have not seen false positives from it to date.

Useful supporting evidence may include reverse engineering showing malicious code or behaviour, observed malicious runtime behaviour such as network exfiltration or persistence and analysis tying the issue to Homebrew-maintained code, metadata, bottles, release infrastructure or checksum verification. Reports are not useful when they only name a detected malware family, repeat a generic malware description or use `brew install` plus a scan as the proof of concept.

### Malicious Search Advertisements

Malicious search results, sponsored links, advertisements or lookalike websites that impersonate Homebrew are not Homebrew security issues unless Homebrew-maintained infrastructure or domains are compromised. We are aware that Google sells malicious search result advertisements targeting Homebrew search terms. Homebrew does not purchase advertising; any sponsored result claiming to be Homebrew is fraudulent by definition. Homebrew cannot control or remove advertisements sold by Google or other advertising platforms. Report malicious advertisements to Google or the relevant advertising platform, not Homebrew.

### Software Not Written by Homebrew

Security vulnerabilities in software used by but not written by Homebrew are not Homebrew security issues. Report these to the affected upstream project instead.

### Local Account or Administrator Control

A report requiring the attacker to control the same user account, administrator account, shell startup files, `PATH`, Homebrew prefix, cache, lock files or repository checkout is not a security issue. Homebrew cannot defend against code already running with the user's privileges.

### Unsupported Configurations

Bugs that only affect Tier 2, Tier 3 or unsupported configurations described in [Support Tiers](https://docs.brew.sh/Support-Tiers) are not security issues unless they also affect Tier 1 configurations. This includes shared multi-user Homebrew installations, non-default prefixes that require source builds, unsupported operating systems, unsupported architectures, deprecated or disabled formulae, `--HEAD` installs and Homebrew installations managed by wrappers such as Nix.

### User-Run Upstream Software

Bugs in software after Homebrew has installed it are not Homebrew security issues. Homebrew may sandbox or filter credentials while it runs install, post-install and test steps, but users are responsible for deciding whether, how and where to run installed software afterwards.

### Local Denial of Service and Resource Exhaustion

Crashes, exceptions, hangs, high CPU usage, disk consumption or memory growth are not security issues when they only stop the current command or require attacker-controlled command-line input, configuration, package metadata from untrusted sources or local files. Report them publicly as quality bugs.

### Documentation Mismatches

Documentation not matching behaviour is not a security issue unless the documented behaviour is a security guarantee that users or callers can reasonably rely on. Otherwise, report the mismatch publicly as a documentation or behaviour bug.

### Homebrew Websites and Hosted Services

Issues that only affect brew.sh websites, brew.sh domain SPF configuration, nominal clickjacking on static GitHub Pages websites or third-party hosted web services Homebrew relies on but does not run are not Homebrew security issues. Examples of third-party hosted services include GitHub and GitHub Pages. InfluxDB analytics and other Homebrew-run infrastructure remain in scope.

## Conduct

While researching, we ask you to refrain from:

- Denial of service
- Spamming
- Social engineering (including phishing) of Homebrew maintainers or contributors
- Any physical attempts against Homebrew's machines
- Performing vulnerability research in public, such as testing discoveries by opening pull requests to Homebrew's public repositories without prior written approval
