# SuvidhaPos Live Sale — GitHub APK Build

1. Create a GitHub repository.
2. Upload/extract this project into the repository.
3. Push to the `main` branch.
4. Open **Actions → Build SuvidhaPos Live Sale APK**.
5. Click **Run workflow** if it did not start automatically.
6. After the workflow succeeds, open the run and download the artifact **SuvidhaPos-Live-Sale**.
7. The artifact contains one universal APK:
   `SuvidhaPos-Live-Sale.apk`

The Android application label is **SuvidhaPos Live Sale** and the existing SuvidhaPos launcher icon is retained.


## CI formatting
The GitHub workflow normalizes Dart formatting with `dart format lib test` before analyze/test/build; it does not fail merely because formatting differs.
