/**
 * Cane Truck Log: send the mill's Daily Cane Receipt emails from Gmail to the truck log.
 * Free, no email service and no domain needed. Runs inside your own Gmail account.
 *
 * 1. Go to script.google.com > New project. Delete what is there and paste this whole file.
 * 2. Fill in ADDRESS (Setup > Mill reports > Make address, in the truck log) and FROM (the mill's email address).
 * 3. Pick setup at the top and press Run. Allow it to read your Gmail and connect to the internet.
 *    That sends any mill report already in Gmail now, and sets it to run once a day, between 8 and 9 in the morning
 *    (the mill's report comes in around 7:30). Change HOUR to move it.
 * Each email it sends is labeled "Cane truck log" in Gmail so it is never sent twice.
 */
const ADDRESS = 'PASTE-THE-ADDRESS-FROM-SETUP-HERE';
const FROM = 'PASTE-THE-MILL-EMAIL-ADDRESS-HERE';   // more than one mill: 'a@mill1.com OR b@mill2.com'
const LABEL = 'Cane truck log';
const HOUR = 8;   // runs once a day between HOUR and HOUR+1 in the morning (the script's time zone: Project Settings)

function setup() {
  ScriptApp.getProjectTriggers().forEach(function (t) { if (t.getHandlerFunction() === 'sendMillReports') ScriptApp.deleteTrigger(t); });
  ScriptApp.newTrigger('sendMillReports').timeBased().everyDays(1).atHour(HOUR).create();
  sendMillReports();
}

function sendMillReports() {
  const label = GmailApp.getUserLabelByName(LABEL) || GmailApp.createLabel(LABEL);
  const threads = GmailApp.search('from:(' + FROM + ') has:attachment filename:pdf -label:"' + LABEL + '" newer_than:10d');
  threads.forEach(function (t) {
    let ok = true;
    t.getMessages().forEach(function (m) {
      m.getAttachments().forEach(function (a) {
        if (!/\.pdf$/i.test(a.getName()) && a.getContentType() !== 'application/pdf') return;
        const r = UrlFetchApp.fetch(ADDRESS, { method: 'post', contentType: 'application/pdf', payload: a.copyBlob().getBytes(), muteHttpExceptions: true });
        console.log(a.getName() + ': ' + r.getContentText());
        if (r.getResponseCode() >= 300) ok = false;
      });
    });
    if (ok) t.addLabel(label);   // a failed send is tried again next time
  });
}
