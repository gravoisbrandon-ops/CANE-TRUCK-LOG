# Cane Truck Log

A shared harvest truck board. Tap the truck number when it is loaded, watch trucks move
Waiting → Loaded → In route, and get a daily report, a day-to-day report and an
all-farms report. Each farm is separate. Plain static site (no build step) on
Vercel, with Supabase for the database and sign-in.

## Set it up (about 15 minutes)

1. **Supabase.** Make a new project (supabase.com).
2. **Sign-in settings.** Authentication > Providers > Email. Turn **Confirm email** off if you
   want people in right after they sign up. Leave it on if you want them to confirm their email first.
3. **Database.** SQL Editor > New query. Paste all of `supabase/schema.sql` and press Run.
4. **Keys.** Project Settings > API. Copy the Project URL and the `anon` / publishable key into `config.js`.
   That key is meant to be public. The tables are locked and every call checks who is signed in.
5. **GitHub.** Make a repo and push these files to it.
6. **Vercel.** Add New > Project > pick the repo. Framework: **Other**. No build command. Deploy.
7. **First sign-up.** Open the site and **create your account first**. The first person to register is
   the administrator. Then open Setup and add the farms, mills (with a color for each), and trucks.

## How people get in

Everyone creates their own account on the site (email, password, name). New people see
"Waiting for approval" until an administrator opens **Setup > People**, sets them to **Crew**
and picks their farm. Crew only ever see their own farm's trucks and loads. Crew can add new trucks (and fix a truck's number or mills) from the **Trucks** tab, but only on their own farm and they can't remove trucks.
An administrator can make others administrators, who see every farm and the **All farms** report.

## Notes

- **Active track and field** (both optional) are chosen at the top of the Board and shared by the whole farm. Every load logged is stamped with them. Crew and administrators can both add or remove track and field names (crew from the Trucks tab). Only administrators manage mills.
- A new calendar date starts a clean board. Trucks stay on the roster.
- The board refreshes every 5 seconds and right after any tap. Time boxes for Loaded and In route are set per device.
- Farm separation is enforced in the database: a crew account cannot read or write another farm's data.
- The earlier Claude-hosted version keeps its own data. Nothing is copied over, so set up farms and trucks again here.
- To lock a person out, remove them under Setup > People.
