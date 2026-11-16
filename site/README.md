# Voltra landing page

From the repository root, run `sh scripts/build-site.sh` after generating the DMG with `./build-installer.sh`. The deployable directory is `build/site`. It includes the page, its assets, the installer and a SHA-256 checksum.

For a local preview:

```sh
python3 -m http.server 8766 --bind 127.0.0.1 --directory build/site
```

The preview is at http://127.0.0.1:8766/.

The intended custom domain is `voltra.caffeeelabs.com.br`. Upload `build/site` to Cloudflare Pages, then associate the subdomain from the Pages project's **Custom domains** settings. Verify HTTPS and download the installer through the published URL to check its checksum.

- [Cloudflare Pages Direct Upload](https://developers.cloudflare.com/pages/get-started/direct-upload/)
- [Cloudflare Pages custom domains](https://developers.cloudflare.com/pages/configuration/custom-domains/)

The support section links to the CaffeeeLabs profile on Buy Me a Coffee. Its button label follows the page language.
