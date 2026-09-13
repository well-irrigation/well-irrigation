#!/bin/sh
# تثبيت نسخة Flutter المحددة للفحص عند غيابها من Cache GitLab.
set -u

root=${CI_PROJECT_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}
ci_dir="$root/.ci"
flutter_dir="$ci_dir/flutter"
archive="$ci_dir/flutter.tar.xz"
version=3.47.0
url="https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${version}-stable.tar.xz"

if [ -x "$flutter_dir/bin/flutter" ]; then
  printf 'FLUTTER_CACHE=HIT version=%s\n' "$version"
  exit 0
fi

mkdir -p "$ci_dir" || exit 2
printf 'FLUTTER_CACHE=MISS version=%s\n' "$version"
curl -fL --retry 3 -o "$archive" "$url"
tar -xJf "$archive" -C "$ci_dir"
rm -f "$archive"
"$flutter_dir/bin/flutter" --no-version-check --version
