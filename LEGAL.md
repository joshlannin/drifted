# Legal notices

Drifted is free, unofficial, open-source software published by Altimix LLC. By using it, or anything in this
repository, you agree to the terms below. They add to the [MIT License](LICENSE) and don't replace it.

## Not affiliated with HoMedics

Drifted is an independent project. It is not made, sponsored, endorsed, approved, supported or otherwise
affiliated with HoMedics, LLC or any of its affiliates, distributors or suppliers. HoMedics doesn't support
it; please don't contact HoMedics about it.

We're fans of the Drift, not partners. Drifted only exists because HoMedics made a lovely table, and it only
works with a genuine HoMedics Drift that you own. If you don't have one, buy one from HoMedics or an
authorized retailer.

## Trademarks

"HoMedics" and "Drift" are trademarks of their owners. Claude, Codex, Cursor, Apple, Mac, macOS, iOS,
Bluetooth and other names are trademarks of their respective owners. These names appear only to say which
products Drifted works with or alongside. Their use doesn't mean their owners are connected with, or endorse,
this project. The Drifted name and icon are not intended to suggest any connection with HoMedics.

## Interoperability

Drifted was written independently so that owners of a Drift table can control a table they own from their
own computer. Specifically:

- It contains no HoMedics software, firmware, source code, stock patterns, artwork, logos or other content,
  and none is needed to use it. The drawings in `designs/` are original works.
- It doesn't modify, replace, extract or redistribute the table's firmware, and it never sends firmware
  updates to the table.
- The table accepts connections without pairing, a password or encryption. Drifted doesn't bypass or
  circumvent any access control, encryption, authentication or copy protection.
- The protocol documentation describes how the table communicates, only as far as needed for
  interoperability.

Contributions must not add any of the above HoMedics material (see [Contributions](#contributions)).

## Use at your own risk

**You use Drifted entirely at your own risk. Altimix LLC, Josh Lannin and the contributors take no
responsibility for anything that happens as a result of using it, or of using anything in this repository.**
Drifted is unofficial software that controls a physical device and runs on your computer, so you accept all
of the risks below, and any others, yourself:

- **Damage to your table.** Unofficial commands and patterns could strain or wear the motors and mechanism,
  drive the ball into the rim, jam or stall the mechanism, overheat parts by running for long periods, or
  otherwise damage the table.
- **Your table stopping working.** The table could behave unexpectedly, lose or corrupt its stored patterns,
  playlists or settings, stop responding, need to be restarted or reset to factory settings, or become
  permanently unusable. Drifted never sends firmware updates, but that doesn't rule this out.
- **Your warranty and support.** Using unofficial software may void or affect your manufacturer's warranty,
  and the manufacturer may refuse to support or repair a table that has been used with it. Check your
  warranty terms before using Drifted.
- **It may stop working.** A firmware or app update from the manufacturer could stop Drifted working at any
  time, and there's no promise it will be fixed. There's no support, no maintenance commitment and no
  guaranteed response to questions or reports.
- **Your computer.** Drifted installs software on your Mac that runs in the background, uses Bluetooth and
  opens a network port. Software can have bugs, conflict with other software, or use power and resources.
- **Security.** Anyone who gets your API token, or who can reach the local API through a misconfigured
  network, could control your table. Keeping your computer, network and token secure is your responsibility.
- **AI assistants.** An AI assistant you connect to Drifted can run commands on your computer, install
  software, change files, send your prompts and photos to its provider, and cost you money in usage fees.
  It can misunderstand you or make mistakes. You choose what it may do, and you're responsible for reviewing
  and approving its actions.
- **Physical safety.** The table has moving parts, magnets, lights and mains power. Follow the manufacturer's
  safety instructions, keep it out of reach of young children and pets as they advise, and don't leave it
  running unattended where it could be a hazard.
- **Accuracy.** The documentation, measurements, timings, designs and digital twin are best-effort
  descriptions from testing a small number of tables. They may be incomplete or wrong, and may not apply to
  your table or firmware version. Don't rely on them.

If you don't accept these risks, don't use Drifted.

## No warranty

TO THE FULLEST EXTENT PERMITTED BY LAW, DRIFTED AND EVERYTHING IN THIS REPOSITORY (THE SOFTWARE, APPS,
DOCUMENTATION, PROTOCOL DESCRIPTIONS, DESIGNS, IMAGES AND ANY OTHER MATERIAL) ARE PROVIDED "AS IS" AND "AS
AVAILABLE", WITHOUT WARRANTY OF ANY KIND, EXPRESS, IMPLIED OR STATUTORY, INCLUDING ANY WARRANTY OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE, TITLE, NON-INFRINGEMENT, ACCURACY, OR THAT IT WILL BE
UNINTERRUPTED, SECURE OR FREE OF ERRORS, OR THAT IT WILL NOT HARM YOUR DEVICE OR DATA.

## Limitation of liability

TO THE FULLEST EXTENT PERMITTED BY LAW, IN NO EVENT WILL ALTIMIX LLC, ITS MEMBERS, MANAGERS, EMPLOYEES OR
AGENTS, JOSH LANNIN, OR ANY CONTRIBUTOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
CONSEQUENTIAL, EXEMPLARY OR PUNITIVE DAMAGES, OR FOR ANY LOSS OF PROFITS, DATA, USE OR GOODWILL, OR FOR
DAMAGE TO OR LOSS OF ANY DEVICE OR PROPERTY, OR FOR PERSONAL INJURY, ARISING OUT OF OR IN CONNECTION WITH
DRIFTED OR ANYTHING IN THIS REPOSITORY, WHETHER IN CONTRACT, TORT (INCLUDING NEGLIGENCE), STRICT LIABILITY OR
OTHERWISE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGES. WHERE LIABILITY CAN'T BE EXCLUDED, IT IS
LIMITED TO THE AMOUNT YOU PAID FOR DRIFTED, WHICH IS ZERO.

Some jurisdictions don't allow certain exclusions or limitations; in those places they apply to the fullest
extent allowed.

## AI assistants and other third-party services

Drifted can be used from AI assistants and other tools made by third parties. Those are separate products
under their own terms and privacy policies, which you are responsible for following. Anything you send to
them, such as prompts and photos, is handled by them, not by Drifted. AI assistants make mistakes: review
what they do on your computer and your table. You are responsible for what you ask them to draw or do.

## Your content and other people's photos

You are responsible for anything you draw or process with Drifted. Only use photos, images and other
material you have the right to use. Before making a portrait of someone, get their permission. Don't use
Drifted for content that infringes anyone's rights or breaks the law.

## Privacy

Drifted collects no personal data and has no analytics or telemetry. It runs on your computer and talks to
your table over Bluetooth; its local API listens on your computer and, if you choose, your local network.
Its logs and settings stay on your computer. It doesn't send anything to Altimix LLC.

## Security

The local API is protected by a token and is meant for your own computer and local network. Don't expose it
to the internet. Report security issues privately, as described in [SECURITY.md](SECURITY.md).

## Contributions

By submitting a contribution (code, documentation, designs, data or anything else), you confirm that you
have the right to submit it and you license it under the MIT License, the same as the project. Contributions
must not include:

- any HoMedics software, firmware, stock patterns, artwork or other
  HoMedics content, or anything derived from them;
- anything obtained in breach of a license, terms of use, non-disclosure or other agreement, or anyone's
  confidential information;
- photos or likenesses of people without their permission.

Contributions that don't meet these terms will be removed.

## Rights holders

If you believe something in this repository infringes your rights, contact the maintainers through GitHub
(use [private vulnerability reporting](../../security/advisories/new) if the matter is confidential). We'll
review it promptly and remove material where appropriate.
