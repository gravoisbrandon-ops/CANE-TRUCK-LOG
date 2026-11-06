# Cane Truck Log

A shared harvest truck board. Tap the truck number when it is loaded, watch trucks move
Waiting → In route, and get a daily report, a day-to-day report and an
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
7. **First sign-up.** Open the site, tap **New here? Create an account**, and give your **portal a name**.
   You become that portal's main administrator. Then open Setup and add the farms, mills (with a color for each), and trucks.

## Separate portals for other growers

One site can serve many growers. Anyone who creates an account and types a **Portal name** starts a brand new, empty portal and becomes its main administrator. Each portal's farms, crew, loads, reports, scale keys and tools are private to it, and the database enforces that. No one can see another portal, including you. Just share the site address with other growers. The main administrator can rename the portal on the Your details page.

An older single-portal copy of this site is moved into the first portal automatically the first time you run the newer `schema.sql`. Nothing changes for the people already using it.

## How people get in

**Roles.** Everyone makes their own account (email + password) on the site.
- **Administrator, main** (the person who started the portal, the account holder): sees every farm, the All farms report and the Tools tab, sees everyone with access and who is assigned to which farm, gets a red number on Setup when someone is waiting to join, adds farms, and names crew managers, other administrators and mill field managers.
- **Administrator, secondary**: sees every farm, the All farms report, the Tools tab, and the crew assigned to each farm.
- **Mill field manager**: view only, tied to one mill. Sees the loads going to that mill from every farm that delivers to it.
- **Crew manager** (one or two per farm, set by the administrator in **Setup > People**): manages their own farm only. Can add, edit and remove trucks, edit mills (with colors), tracks and fields, copy or renew the farm's invite link, and make crew into managers or remove them.
- **Crew**: log loads, add and edit trucks, and edit tracks and fields on their own farm only.

**Inviting crew.** In Setup > People, copy the farm's **Invite link** and text it to the crew member. They open it and create their account. They then wait on an approval page until an administrator approves them in **Setup > People** (the red number on Setup shows who is waiting). **New link** makes a fresh one and the old one stops working. Anyone who signed up without a link sees a "Waiting" page where they can paste a code, or an administrator can place them.

## Scale connection (weights and quotas)

Each farm can have a secret key (Setup > Scale connection, for administrators and that farm's crew manager). Whoever runs the scale app uses it to send:

- **Net weight per load**: truck number + tons (TRS and ticket number are optional). The weight goes onto that truck's oldest load that has no weight yet. If the truck has not been tapped yet, the weight waits and lands on the load the moment it is tapped.
- **Quota**: tons and/or loads, for the whole farm or one mill, for the day.

**One key per mill, for every grower on the site:** the site owner (the first administrator) makes one key for each mill in Setup > Scale connection. The mill's scale app uses it to send weights for all growers in all portals. It can send the mill's own truck ID like `54-154` (hauler number + truck number) and the weight lands on the right grower's load by their hauler number from Setup; with only `154` it goes on the oldest unweighed load for that truck going to that mill. Add `p_farm` if two growers share a number. A quota with a mill key needs `p_farm`. Farm keys made earlier keep working (Older farm keys). Run the new `supabase/schema.sql` before the matching `index.html`.

**Brix and final TRS:** the mill can send `p_brix` with each weight, and later call `scale_final` with the load's ticket number and the final `p_trs` (and/or `p_brix`). The final TRS replaces the first one on that load (the first is kept as the estimate), the load is marked final, and every report and Cane Track use it from then on. Reports show Average brix, "TRS final: x of y", a Brix column in the load log and CSV, and a Brix and final checkbox when you edit a load.

Tap **Copy instructions** on a mill (or an older farm key) to get a ready-to-send text with the web address and example calls. The key is shown only once when it is made. **New key** replaces it (the old one stops working immediately); **Turn off** disconnects the scale. Truck numbers in the truck log must match the scale's truck numbers, and mill names in a quota must match the mill names in Setup.

Tons, average TRS and quota progress show on the Board; the Reports and CSV include tons, TRS and ticket numbers. A manager or administrator can also type or fix a load's tons and TRS by hand (tap the load).

## Reports and metrics

- **Time between loads**: each load shows a Trip time that stops when the truck is loaded again. The Report shows the average time between loads by track, per truck, loads per hour by track and farm, and a per-truck efficiency (100% = the average for trucks hauling to the same mill from the same track, since mills are different distances). Gaps under 10 minutes or over 4 hours are not counted.
- **Harvest to date**: a Report mode that adds up the season from the farm's Begin harvest date (September 1 until changed).
- A truck added on a day keeps its new-truck mark all day and in the reports, even after it is weighed.

## Tools tab (administrators)

Run the latest `supabase/schema.sql` once so the Tools data is shared between administrators. Without it the tools still work but save on that device only.

- **Tank mix**: product list without prices. Prices are added by uploading a CSV (product, price, per, year, optional category), pasting rows, or typing them. Prices are never included when a mix is sent.
- **Cane Track** (first chip; the old Sugar per acre):  per mill (tons x TRS x liquidation), combined per farm and for all farms, with a date, saved sets, a progress table, edit and CSV. Tons and TRS can be fetched from the truck log.
- **Burn log**: farm, track and field, date and time, and weather. Fetch weather fills in the category day, mixing height and transport wind from the National Weather Service fire weather forecast for the burn's zone, plus the readings from the nearest weather station. Each farm has its own list and its own CSV. Wind shows the compass point (N, NNE, SW…) with the degrees, and either can be edited.

## Notes

- **Active track and field** (both optional) are chosen at the top of the Board and shared by the whole farm. Every load logged is stamped with them. Crew and administrators can both add or remove track and field names (crew from the Trucks tab). Administrators and crew managers manage mills.
- A new calendar date starts a clean board. Trucks stay on the roster.
- The board refreshes every 5 seconds and right after any tap. The time a truck stays In route before returning to Waiting is set per device.
- Farm separation is enforced in the database: a crew account cannot read or write another farm's data.
- The earlier Claude-hosted version keeps its own data. Nothing is copied over, so set up farms and trucks again here.
- To lock a person out, remove them under Setup > People.

- **Share PDF report**: the Report, All farms report, Sugar per acre and Burn log each have a Share PDF report button. It makes a PDF on the phone and opens the share sheet (text, email, print), or downloads it. Sugar per acre shows one farm at a time, or All farms combined with every farm broken down by mill and the total.

- **Burn log, gust and best time**: the weather has a wind gust box (filled in when the station reports a gust). Gusts show on the screen but are left out of the CSV and PDF. Next to the category day it shows the best time to burn (for example, category 2: 11 am until 4 pm) and warns if the burn time is outside it. The All farms report has a Harvest to date choice in Days to show, with each farm's loads, days, trucks and tons and the total.
- **Sugar per acre, checkpoints**: each saved set is an end-of-day checkpoint, newest on top. Pick a month, or choose Since and To dates (any saved date, the numbers on screen, or the start of harvest), to see the results of just that period: new acres, tons hauled, average TRS, tons per acre and lb sugar per acre, worked out as the new total minus the old total. Below is the running average from the start through each checkpoint, with total lb sugar last. Both are in the PDF.
- **Tools for crew managers**: a crew manager now sees the Tools tab with Sugar per acre and Burn log for their own farm only and the shared Tank mix recipes (managers can use and edit them, like administrators). Their burn and sugar data is kept in separate per-farm documents, so a manager cannot see or change another farm's logs. Administrators still see every farm. Run the latest `supabase/schema.sql` first. The first time an administrator saves in either tool, the older combined log is split into per-farm documents automatically.
- **Truck ID at the mill**: in Setup, an administrator can enter a farm's hauler number (for example 54) and tick the mills that know a truck as hauler-truck (for example Lula Westfield and Lafourche). The Board keeps the 3 digit number. For loads going to the ticked mills, the load log shows the mill ID next to it (54-154) and the CSVs have a Mill truck ID column.
- **Edgard tracts**: each farm card in Setup has an Add the Edgard tracts button that adds the 11 Edgard tracts to the farm's tracks (only the ones not already there).

## Backup and restore
Setup > **Backup** (administrators) has **Save to phone**, which downloads everything (loads, trucks, tracks, fields, Cane Track, Seasons, burn log, yield) as one file, and **Restore from phone**, which loads that file back. Save a copy before big changes.

## Trucks and farms
- **Batch edit** (Setup, trucks card): change the mill, hauler or other fields on many trucks at once, or clear a mill's trucks and start again. Old logged loads are not changed.
- **Copy from another farm**: each farm keeps its own tracks, fields and varieties. Copy a list from another farm once, then edit it; the farms stay separate. Reports can still combine them.
- **Mill start date**: pick the date, then tap **Set** (or **Clear**). It only saves when you tap Set.

## Cane Track, step by step
1. **Date of this data set** is the first entry on each farm's card. Set it to the day the numbers are for.
2. Enter **Acres harvested so far**, then tons and TRS per mill (or fetch them from the truck log).
3. **Estimate for the rest**: total acres to harvest, **Remainder est. tons per acre** and **Remainder est. TRS**. The projections blend what is already hauled with this estimate.
3b. **Cutting for another farm** (below the mills): if your crew cuts cane for a different farm, tap **+ Add cane cut for another farm**, pick the farm and enter its acres, tons and TRS. It stays out of your farm's totals and counts in the other farm's. Both cards say so, and the reports show a "cut for" line on your farm and an "of which cut by" line on theirs.
4. **Projections** show the projected total tons and lb sugar per acre for each farm and for all farms combined.
5. **Save as new set** keeps the day's totals as a checkpoint. Pick a week in the weekly picker to see just that week's results.
6. At the bottom, **How we compare to prior years** shows tons hauled by day of harvest against last season, and bar charts of total tons, tons per acre and lb sugar per acre by year, with this year's projection in amber. It only appears when there is earlier data (import it in Seasons). In All farms, each farm's week to week stays separate.
7. **Share PDF report** and **View PDF** make the Cane Track report: farm table, a **Last week** table (each farm's latest week, tons this week, last year's tons at the same point, ahead or behind, and an All farms combined row), results, left to harvest, checkpoints and the comparison charts.

## Seasons: history and week by week
Import past years (columns above) and the weekly sheet (**Import weekly history**: date, farm, acres, total_acres, tons, trs, est_tons_per_acre, projected_trs, projected_tons, projected_lb_sugar_per_acre). **Week by week** shows this season against last year at the same week. Saving a set in Cane Track adds that week by itself. The Seasons PDF opens with the charts.

## Burn log and smoke map
The smoke map is part of the Burn log now, shown inline. Choosing a burn from the Board fills in the track and field being harvested.

## Yield check and administrators
Yield check data is shared, so administrators see every farm's samples and all Tools data. Managers see their own farm's.

## Day counter (Tools)
**Day counter** gives the days between two dates (also in weeks and days, and counting both dates), and adds or subtracts a number of days from a date (use a minus sign to go back).

## Cane varieties

Each farm has a list of cane varieties (Setup farm card, or **+ Add or edit…** in the Board's Cane variety picker, which crew can also use). The picked variety is shared like the active track and field and is stamped on every load; fix it per load with Edit. The Report adds a **by cane variety** table (loads, tons, average TRS) and the CSV has a Variety column. Run the new `supabase/schema.sql` so crew can edit the list.

## Left to harvest and ship (Cane Track)

Each farm card has **Total acres to harvest** and **Estimated tons per acre**. Cane Track shows acres harvested (%), **acres remaining**, **estimated tons left to ship** (remaining acres x estimate) and the projected total tons. Leave the estimate blank to use the tons per acre so far. All farms combined adds a table by farm and the total, and the PDF includes it.

## Seasons (year after year)

Tools > **Seasons** keeps each year's result per farm (acres, tons, TRS, lb sugar) inside that farm's Cane Track document, so crew managers see their own farm and administrators see all. **Save this season from Cane Track** copies the numbers now in Cane Track for a year you type (saving the same year again replaces it). Past years can be typed in by hand, edited and deleted, or imported: pick a CSV file or paste rows with the columns `year, farm, acres, tons, trs, liquidation, lb_sugar, notes` (a template can be downloaded; the farm name must match a farm on the site; a row for a farm and year already saved replaces it). The analytics show years saved, average lb sugar/acre, tons/acre and TRS, the last 5 year average, the best year, bar charts by year with the current season in amber, a by-year table with the change from the year before, a compare-two-years table, and for All farms a farm-by-year table. A PDF can be shared or viewed. No SQL change is needed.

## End-of-day totals

Admins and managers can type a day's total tons and TRS per track and/or field (Reports tab, "End of day totals"), for any day including yesterday, for days without mill weights. Typed totals stand in for the logged loads they cover, show in Reports under "breakdown by track and field", and Cane Track's fetch includes them (checkbox "Include end-of-day totals", on by default). Stored in the farm's `tools/sugarlog-<farm>` doc as `dayTotals`; no SQL change.


## Smoke map (admin only, trial)
Admins see a "Smoke map (trial)" chip in Tools, a "Smoke map" button on each saved burn, and "See smoke map" on the burn form. It opens `smoke-trial.html` with the burn's location, start time and the weather fetched in the Burn log. The page shows a projection only, with a disclaimer. Each time the map is viewed from a burn, the estimate (thick smoke miles, fire out time, lift, ash distance, fog) is saved in that burn entry as `smoke`. It is never shown in the Burn log list, CSV or PDF. No SQL change. Upload `index.html` and `smoke-trial.html` together.

### Saved smoke picture and report choice
Opening the Smoke map from a burn also saves a small picture of the projection and its description in that burn entry (`smoke.pic`, `smoke.desc`). Admins can open it later with "Saved smoke". The Saved burns card has a checkbox, "Include smoke projections in the PDF and CSV", off by default. When it is on, the PDF adds the picture and description for each burn that has them, and the CSV adds a `smoke_projection` column.

## Yield check (Tools)
Mark A, drive to B, and Mark B take the phone location and add up the distance. Pause skips the headland turn. Distance times row width times rows cut gives the area cut. Weight (tons or pounds) divided by that area gives tons per acre. Each pass saves with farm, field, variety, stubble year, harvest year and date, and stays on that phone. Download the CSV to keep a copy.

## Mill start dates
Each mill has its own start date in Setup, per farm. Cane Track fetch and the roll-up reports leave out a mill's loads from days before its start date. The Board shows "(starts Oct 17)" next to the mill until then. Managers need the latest `schema.sql` to set it (admins do not).

## Renaming mills, tracks, fields and varieties
A rename carries everything with it: trucks set to the mill, all logged loads since harvest start, typed day totals, burn log entries (track and field), and a mill's color, start date and hauler codes. If something is still stuck on an old mill name, Setup has "Trucks tied to a mill name that is gone" and "Check logged loads for old mill names", each with a Move button.

## Housekeeping
`index2.html` is an old unused page and can be deleted. `config.js` holds your own Supabase address and key, so never replace it with a file from anyone else.
