import boto3
import datetime
import os

def fmt_int(n):
    return f"{n:,}"

def fmt_gb(n):
    return f"{n:,} GB"

def lambda_handler(event, context):
    ec2 = boto3.client('ec2')
    ses = boto3.client('ses', region_name=os.environ['SES_REGION'])

    # --- required / optional environment variables ---
    ARCHIVE_RETENTION_DAYS = int(os.environ['ARCHIVE_RETENTION_DAYS'])
    ACTIVE_ARCHIVE_INTERVAL = int(os.environ['ACTIVE_ARCHIVE_INTERVAL'])
    SES_SENDER = os.environ['SES_SENDER']          # verified SES identity (email or domain)
    SES_RECIPIENT = os.environ['SES_RECIPIENT']
    SES_SUBJECT = os.environ['SES_SUBJECT']        # subject line for the email

    SES_FROM_NAME = os.environ.get('SES_FROM_NAME', '')   # e.g., "Backup Bot"
    SES_REPLY_TO = os.environ.get('SES_REPLY_TO', '')     # e.g., "ops@example.com"

    # Build Source with friendly display name if provided
    source_address = f"{SES_FROM_NAME} <{SES_SENDER}>" if SES_FROM_NAME else SES_SENDER

    now = datetime.datetime.now(datetime.timezone.utc)

    # --- 1) map VolumeId → Name ---
    vols = ec2.describe_volumes()['Volumes']
    volume_name_map = {
        v['VolumeId']:
          next((t['Value'] for t in v.get('Tags', []) if t['Key'] == 'Name'),
               v['VolumeId'])
        for v in vols
    }

    # --- 2) list all standard-tier snapshots (active) ---
    active_snaps = ec2.describe_snapshots(
        OwnerIds=['self'],
        Filters=[{'Name': 'storage-tier', 'Values': ['standard']}]
    )['Snapshots']

    # --- 3) list all archive-tier snapshots ---
    archived_snaps = ec2.describe_snapshots(
        OwnerIds=['self'],
        Filters=[{'Name': 'storage-tier', 'Values': ['archive']}]
    )['Snapshots']

    # group by volume
    active_by_vol = {}
    for s in active_snaps:
        active_by_vol.setdefault(s['VolumeId'], []).append(s)
    archived_by_vol = {}
    for s in archived_snaps:
        archived_by_vol.setdefault(s['VolumeId'], []).append(s)

    archived_this_run = 0
    # --- 4) archive logic ---
    for vol_id, snaps in list(active_by_vol.items()):
        current_archives = archived_by_vol.get(vol_id, [])
        # find most recent archive date
        if current_archives:
            most_recent = max(
                (next((datetime.datetime.fromisoformat(t['Value'])
                       for t in s.get('Tags', [])
                       if t['Key'] == 'ArchiveDate'),
                      s['StartTime'])
                 for s in current_archives)
            )
            delta = (now - most_recent).days
            if delta < ACTIVE_ARCHIVE_INTERVAL:
                continue
        # if no archives or interval met, archive the newest standard snapshot
        if snaps:
            to_archive = max(snaps, key=lambda s: s['StartTime'])
            sid = to_archive['SnapshotId']
            try:
                ec2.modify_snapshot_tier(SnapshotId=sid, StorageTier='archive')
                ec2.create_tags(
                    Resources=[sid],
                    Tags=[{'Key': 'ArchiveDate', 'Value': now.isoformat()}]
                )
                # move it in our local groups
                active_by_vol[vol_id].remove(to_archive)
                archived_by_vol.setdefault(vol_id, []).append(to_archive)
                archived_this_run += 1
            except Exception as e:
                print(f"Error archiving {sid}: {e}")

    deleted_this_run = 0
    # --- 5) deletion logic ---
    for vol_id, snaps in list(archived_by_vol.items()):
        for s in list(snaps):
            sid = s['SnapshotId']
            # get ArchiveDate tag or fallback to StartTime
            archive_date = None
            for t in s.get('Tags', []):
                if t['Key'] == 'ArchiveDate':
                    try:
                        archive_date = datetime.datetime.fromisoformat(t['Value'])
                    except:
                        pass
            if archive_date is None:
                archive_date = s['StartTime']
            age = (now - archive_date).days
            print(f"Checking deletion for {sid}: age={age}d")
            if age >= ARCHIVE_RETENTION_DAYS:
                try:
                    ec2.delete_snapshot(SnapshotId=sid)
                    archived_by_vol[vol_id].remove(s)
                    deleted_this_run += 1
                except Exception as e:
                    print(f"Error deleting {sid}: {e}")

     # --- 6) build the final, mobile-friendly HTML (card layout) ---

    # collect final counts/sizes
    final_standard = sum(len(v) for v in active_by_vol.values())
    final_archive  = sum(len(v) for v in archived_by_vol.values())
    final_total    = final_standard + final_archive

    # Build volume "cards"
    volume_cards = []
    all_dates = []

    def card_row(label, value):
        return f"""
          <tr>
            <td style="padding:8px 0; color:#475467; font-size:14px;">{label}</td>
            <td style="padding:8px 0; text-align:right; font-size:14px; font-weight:600;">{value}</td>
          </tr>
        """

    for vol_id in sorted(set(active_by_vol) | set(archived_by_vol)):
        name = volume_name_map.get(vol_id, vol_id)
        a_list = active_by_vol.get(vol_id, [])
        x_list = archived_by_vol.get(vol_id, [])
        ac = len(a_list);  asz = sum(s['VolumeSize'] for s in a_list)
        xc = len(x_list);  xsz = sum(s['VolumeSize'] for s in x_list)
        tc = ac + xc;      tsz = asz + xsz

        dates = [s['StartTime'] for s in a_list + x_list]
        if dates:
            e_age = (now - min(dates)).days
            l_age = (now - max(dates)).days
            all_dates += dates
        else:
            e_age = l_age = "N/A"

        card_html = f"""
          <!-- volume card -->
          <table role="presentation" cellspacing="0" cellpadding="0" border="0" width="100%"
                 style="border:1px solid #e9eaeb; border-radius:12px; margin:0 0 12px 0;">
            <tr>
              <td style="background:#f6f7fb; border-bottom:1px solid #e9eaeb; padding:12px 14px; font-weight:700; font-size:15px;">
                {name}
              </td>
            </tr>
            <tr>
              <td style="padding:12px 14px;">
                <table role="presentation" cellspacing="0" cellpadding="0" border="0" width="100%">
                  {card_row("Active",   f"{fmt_int(ac)} <span style='color:#667085; font-weight:400;'>({fmt_gb(asz)})</span>")}
                  {card_row("Archived", f"{fmt_int(xc)} <span style='color:#667085; font-weight:400;'>({fmt_gb(xsz)})</span>")}
                  {card_row("Total",    f"{fmt_int(tc)} <span style='color:#667085; font-weight:400;'>({fmt_gb(tsz)})</span>")}
                  {card_row("Earliest Age (d)", e_age)}
                  {card_row("Latest Age (d)",   l_age)}
                </table>
              </td>
            </tr>
          </table>
        """
        volume_cards.append(card_html)

    # grand totals for footer card
    if all_dates:
        ge = (now - min(all_dates)).days
        gl = (now - max(all_dates)).days
    else:
        ge = gl = "N/A"

    totals_card = f"""
      <table role="presentation" cellspacing="0" cellpadding="0" border="0" width="100%"
             style="border:1px solid #e9eaeb; border-radius:12px; margin:8px 0 0 0;">
        <tr>
          <td style="background:#eef2ff; border-bottom:1px solid #e9eaeb; padding:12px 14px; font-weight:700; font-size:15px;">
            Totals
          </td>
        </tr>
        <tr>
          <td style="padding:12px 14px;">
            <table role="presentation" cellspacing="0" cellpadding="0" border="0" width="100%">
              {card_row("Standard snapshots (post-run)", f"{fmt_int(final_standard)} <span style='color:#667085; font-weight:400;'>({fmt_gb(sum(sum(s['VolumeSize'] for s in v) for v in active_by_vol.values()))})</span>")}
              {card_row("Archive snapshots (post-run)",  f"{fmt_int(final_archive)} <span style='color:#667085; font-weight:400;'>({fmt_gb(sum(sum(s['VolumeSize'] for s in v) for v in archived_by_vol.values()))})</span>")}
              {card_row("Total snapshots (post-run)",    fmt_int(final_total))}
              {card_row("Earliest Age (d)",              ge)}
              {card_row("Latest Age (d)",                gl)}
            </table>
          </td>
        </tr>
      </table>
    """

    # badges
    archived_badge = f"""<span style="display:inline-block; padding:4px 10px; border-radius:999px;
                                     background:#ecfdf3; color:#027a48; font-size:12px;
                                     border:1px solid #abefc6;">Archived this run: {fmt_int(archived_this_run)}</span>"""
    deleted_badge  = f"""<span style="display:inline-block; padding:4px 10px; border-radius:999px;
                                     background:#fef3f2; color:#b42318; font-size:12px;
                                     border:1px solid #f9d3cf; margin-left:8px;">Deleted this run: {fmt_int(deleted_this_run)}</span>"""

    # KPI strip (no spacer cells; each cell 1/3 width)
    kpi_row = f"""
      <table role="presentation" cellspacing="0" cellpadding="0" border="0" width="100%" style="margin:12px 0 14px 0;">
        <tr>
          <td style="width:33.33%; padding:12px; border:1px solid #e9eaeb; border-radius:12px; text-align:center;">
            <div style="font-size:12px; color:#667085; margin-bottom:4px;">Standard snapshots (post-run)</div>
            <div style="font-size:18px; font-weight:700;">{fmt_int(final_standard)}</div>
          </td>
          <td style="width:2%"></td>
          <td style="width:33.33%; padding:12px; border:1px solid #e9eaeb; border-radius:12px; text-align:center;">
            <div style="font-size:12px; color:#667085; margin-bottom:4px;">Archive snapshots (post-run)</div>
            <div style="font-size:18px; font-weight:700;">{fmt_int(final_archive)}</div>
          </td>
          <td style="width:2%"></td>
          <td style="width:33.33%; padding:12px; border:1px solid #e9eaeb; border-radius:12px; text-align:center;">
            <div style="font-size:12px; color:#667085; margin-bottom:4px;">Total snapshots (post-run)</div>
            <div style="font-size:18px; font-weight:700;">{fmt_int(final_total)}</div>
          </td>
        </tr>
      </table>
    """

    # header & footer
    run_ts = now.strftime("%Y-%m-%d %H:%M:%S %Z")
    fn_name = getattr(context, "function_name", "UnknownFunction")

    html = f"""
    <html>
      <body style="margin:0; padding:0; background:#f7f7f7; font-family:-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif; color:#111827;">
        <table role="presentation" cellspacing="0" cellpadding="0" border="0" width="100%" style="padding:16px;">
          <tr>
            <td>
              <table role="presentation" cellspacing="0" cellpadding="0" border="0" width="100%" style="max-width:800px; margin:0 auto; background:#ffffff; border:1px solid #e9eaeb; border-radius:12px;">
                <tr>
                  <td style="padding:18px 20px; border-bottom:1px solid #e9eaeb; background:#fbfbfb;">
                    <div style="font-size:18px; font-weight:700;">EC2 Snapshot Summary</div>
                    <div style="font-size:12px; color:#667085; margin-top:4px;">Run time: {run_ts} &nbsp;•&nbsp; Lambda: {fn_name}</div>
                    <div style="margin-top:10px;">{archived_badge} {deleted_badge}</div>
                  </td>
                </tr>

                <tr>
                    <td style="padding:16px 20px;">
                      {kpi_row}

                      <!-- volume cards -->
                      {''.join(volume_cards)}

                      {totals_card}

                      <div style="font-size:12px; color:#6b7280; margin-top:14px;">
                        Tip: counts show snapshot totals; values in parentheses show total provisioned size (GB).
                      </div>
                    </td>
                </tr>

                <tr>
                  <td style="padding:12px 20px; border-top:1px solid #e9eaeb; background:#fbfbfb; font-size:12px; color:#6b7280;">
                    This message was generated automatically by AWS Lambda. Please do not reply directly to this email unless a Reply-To address is set.
                  </td>
                </tr>
              </table>
            </td>
          </tr>
        </table>
      </body>
    </html>
    """

    # --- 7) send via SES ---
    send_kwargs = {
        'Source': source_address,
        'Destination': {'ToAddresses': [SES_RECIPIENT]},
        'Message': {
            'Subject': {'Data': SES_SUBJECT},
            'Body': {'Html': {'Data': html}}
        }
    }
    if SES_REPLY_TO:
        send_kwargs['ReplyToAddresses'] = [SES_REPLY_TO]

    ses.send_email(**send_kwargs)
    print("Email sent.")

    return {"status": "Completed"}
