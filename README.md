# Crown & Conquest

Official site for the Windows game, served at [https://crownandconquest.net](https://crownandconquest.net). GitHub Pages publishes the repository root. There is no build step.

The downloadable build is `downloads/CrownAndConquest-windows.zip` (v0.1.0). News and the forums read and write through Supabase. Apply `sql/0009_site_news_forums.sql` in the SQL editor when you want those halls to open. Do not put a service-role key in this repo.

The earlier browser game is parked at `/legacy/` and is not linked from the site navigation. Its tests still run from the repository root:

```sh
npm test
```
