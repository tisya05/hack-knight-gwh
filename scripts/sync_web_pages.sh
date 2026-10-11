#!/bin/sh
# Copies the two dashboards into the backend so hear-echora.us serves them:
#   live-dashboard/static -> backend/app/web/live     (/)
#   dashboard/            -> backend/app/web/results  (/results/)
# Run after changing either page, then commit both. (Render may deploy from
# backend/ only, so the backend keeps its own copy.)
set -e
cd "$(dirname "$0")/.."
rm -rf backend/app/web
mkdir -p backend/app/web/live backend/app/web/results
cp live-dashboard/static/index.html live-dashboard/static/app.js live-dashboard/static/styles.css backend/app/web/live/
cp dashboard/index.html dashboard/app.js dashboard/styles.css backend/app/web/results/
echo "Synced live-dashboard/static and dashboard/ into backend/app/web"
