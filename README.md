# JumpShot PWA

Web-app version of JumpShot: detects a jump in the camera preview and shoots a burst of stills.
Install it from the browser ("Install app" / "Add to Home screen"); it works offline after the first launch.

## Hosting
The camera only works on an **HTTPS** page (or `http://localhost` on the same device).
Upload this whole folder, as is, to any static host, for example:
- Netlify Drop (app.netlify.com/drop): drag this folder onto the page.
- GitHub Pages: push the folder to a repo and turn on Pages.
- Cloudflare Pages, Firebase Hosting, your own web server.

Local test on the PC: `python -m http.server 8080` in this folder, then open http://localhost:8080.

## Files
- index.html, app.js, detector.js: the app (detector.js is the same algorithm as the Android app)
- sw.js, manifest.webmanifest, icons/: PWA install + offline
- vendor/mediapipe/ (optional): MediaPipe Tasks Vision 1.2.3 (Apache-2.0). If it's not deployed, the app loads the same version from jsDelivr
- models/ (optional): put `pose_landmarker_lite.task` here to avoid downloading it from Google on first launch

## Photos
Photos are stored inside the app (IndexedDB) on the device. Use Share or Download in the Photos screen
to save them to the gallery: browsers don't let web apps write to the gallery directly.
