# Disclaimer

AI Sphere is an independent, personal open-source project, provided **"as is", without warranty of any kind**, as stated in the [MIT License](LICENSE). By using it you accept that you do so at your own risk.

## No affiliation

AI Sphere is not affiliated with, endorsed by or sponsored by Garmin, CodexBar, Bunny.net, Cloudflare, Amazon Web Services, Backblaze, OpenAI, Anthropic, Google, NaN Builders (HelmCode) or any other company or service mentioned in this repository. All product names, logos and trademarks are the property of their respective owners and are used here only to identify compatible products and services.

The Lostium logo shown on the watch face and in the prototype is a trademark of [Lostium](https://lostium.com), the project's author. It is **not** licensed under the MIT License: if you fork or redistribute AI Sphere, remove it (`drawLogo` in `garmin/source/AISphereView.mc` and the logo in `prototype/index.html`) or ask Lostium for permission.

## Accuracy of the data

The quota figures shown on the watch come from CodexBar and from the providers' own endpoints, and may be incomplete, estimated, delayed (up to about half an hour) or wrong. Providers can change their limits, plans or APIs at any time without notice. **Do not rely on AI Sphere for billing, budgeting or any decision where an error matters**; check the provider's own dashboard.

## Unofficial integrations

Some integrations, such as the HelmCode credits plugin, use undocumented endpoints and a session cookie from your own browser session. They may stop working at any time, and using them may not be permitted by a provider's terms of service. You are responsible for reviewing and complying with the terms of every service you connect, and for keeping your own credentials, cookies and keys safe.

## Hosting, security and costs

You choose and operate the place where `usage.json` is published (Bunny, Cloudflare, an S3-compatible store, your own server…). You are responsible for its configuration, security, access controls and any costs it incurs. The `X-Key` header and hard-to-guess URLs reduce exposure but are not strong authentication; do not publish anything you would not accept being read by a third party. The published file is designed to contain only quota percentages, reset times and short labels.

## Your watch and computer

The watch face is installed by sideloading, outside the Connect IQ Store, and has not been reviewed by Garmin. Background downloads use Bluetooth and the phone's data connection and may affect battery life. The macOS publisher runs periodically in the background and reads secrets from your Keychain. The authors are not responsible for any damage, data loss, battery drain, account suspension, charges or other consequences arising from installing or using this software.
