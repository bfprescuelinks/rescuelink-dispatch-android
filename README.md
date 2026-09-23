# RescueLink Dispatch Android

Mobile command app for authorized BFP dispatch personnel. It connects to the existing RescueLink Firebase project and displays incoming incidents, live GPS movement, reporter details, incident history, and response controls.

## Dispatcher access

The signed-in Google account must have a Firestore document at `users/{uid}` with `role` set to `dispatcher`, `responder`, or `admin`.

## APK

Open **Actions**, select the latest successful **Build RescueLink Dispatch APK** run, and download the `RescueLink-Dispatch-Android` artifact.

