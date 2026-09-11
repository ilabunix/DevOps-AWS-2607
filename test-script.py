#!/usr/bin/env python3

import argparse
import boto3
import fnmatch
import re
import sys

from collections import defaultdict
from datetime import datetime
from pathlib import Path


# =============================================================================
# TERMINAL COLORS
# =============================================================================

USE_COLOR = True


class Color:
    RESET = "\033[0m"
    BOLD = "\033[1m"

    RED = "\033[91m"
    GREEN = "\033[92m"
    YELLOW = "\033[93m"
    BLUE = "\033[94m"
    CYAN = "\033[96m"


def ctext(text, color):
    if not USE_COLOR:
        return text

    return f"{color}{text}{Color.RESET}"


# =============================================================================
# AWS CONFIGURATION
# =============================================================================

PROD_PROFILE = (
    "cfs-base01-gov-core1custmgmtp-prod_<PROD_ACCOUNT_ID>_cfs-adt-admin-role"
)

UAT_PROFILE = (
    "cfs-base01-gov-core1custmgmtp-uat_<UAT_ACCOUNT_ID>_cfs-adt-admin-role"
)

PROD_REGION = "us-gov-east-1"
UAT_REGION = "us-gov-west-1"


# =============================================================================
# PROD BUCKETS
# =============================================================================

FLB_BUCKET = "adt-frfs-compass-prod-e-s3-flb-data-transfer"

SFDM_BUCKET = "adt-frfs-compass-prod-e-s3-salesforce-data-movement"
SFDM_ROOT_PREFIX = "incoming/"

DATAPLATFORM_BUCKET = "adt-frfs-compass-prod-e-s3-partners-data-exchange"
DATAPLATFORM_PREFIX = "from_compass/dmpt/"

WPO_BUCKET = "adt-frfs-compass-prod-e-s3-incoming-files"
WPO_PREFIX = "wpo/message/"


# =============================================================================
# UAT DESTINATION
# =============================================================================

UAT_BUCKET = "adt-frfs-compass-uat-w-s3-file-comparator"

UAT_PREFIXES = {
    "FLB": "cloud/flb/",
    "SFDM": "cloud/sfdm/",
    "DATAPLATFORM": "cloud/dataplatform/",
    "WPO": "cloud/wpo/",
}


# =============================================================================
# FLB CONFIGURATION
# =============================================================================

FLB_PREFIXES = {
    "AccountingServices": "accountingservices/input-folder/",
    "Epayment": "epayment/input-folder/",
    "FedMail": "fed-mail/input-folder/",
    "Fta": "fta/input-folder/",
    "OrgProfile": "org-profile/input-folder/",
    "Router": "router/input-folder/",
    "ServerCert": "server-cert/input-folder/",
    "Subscriber": "subscriber/input-folder/",
    "VpnDevice": "vpn-device/input-folder/",
    "VpnMissed": "vpn-missed/input-folder/",
    "VpnModification": "vpn-modification/input-folder/",
    "VpnReplacement": "vpn-replacement/input-folder/",
}


# =============================================================================
# SFDM CONFIGURATION
# =============================================================================

SFDM_FAMILIES = [
    "AccountingServices",
    "WebServices",
    "ActiveWebSubscribers",
    "FedAch",
    "WebSubscriberServices",
    "Organization",
    "ServiceProvider",
    "ServerCert",
    "ServerCertServices",
    "OrganizationSettlement",
    "VpnData",
    "FedlineServices",
    "EasyMonthlyBilling",
]


# =============================================================================
# DATAPLATFORM CONFIGURATION
# =============================================================================

DATAPLATFORM_FAMILIES = [
    "AllFedmailSubscribers",
    "ArrangementAgent",
    "ArrangementSettlement",
    "ContactAddresses",
    "Countries",
    "GcdAddress",
    "GcdProfile",
    "Interest",
    "MergersInTransition",
    "Oc1NonCompliance",
    "OrgLterm",
    "OrgSettlement",
    "Router",
    "SecuritiesAccount",
    "ServiceInteraction",
    "ServiceProvider2",
    "SettlerArrangement",
    "StateProvince",
    "Subscriber",
    "SubscriberServices",
    "VpnData",
]


# =============================================================================
# WPO CONFIGURATION
# =============================================================================

WPO_PATTERNS = {
    "DNBES Intraday 04": "dnbesIntradayJob.04*",
    "LCD Intraday 04": "lcdIntradayJob.04*",
    "ABS Intraday 01": "absIntradayJob.01.*",
    "DNBES EOD": "dnbesEodJob.*",
    "LCD EOD": "lcdEodJob.*",
    "ABS EOD": "absEodJob.*",
}


# =============================================================================
# GENERAL HELPERS
# =============================================================================

def confirm(message):
    answer = input(
        f"\n{ctext(message, Color.CYAN)} "
        f"{ctext('[y/N]:', Color.CYAN + Color.BOLD)} "
    ).strip().lower()

    return answer in ("y", "yes")


def human_size(num_bytes):
    size = float(num_bytes)

    for unit in ["B", "KB", "MB", "GB", "TB"]:
        if size < 1024:
            return f"{size:.2f} {unit}"

        size /= 1024

    return f"{size:.2f} PB"


def object_basename(key):
    return key.rstrip("/").split("/")[-1]


def list_objects(s3, bucket, prefix=""):
    paginator = s3.get_paginator("list_objects_v2")

    for page in paginator.paginate(
        Bucket=bucket,
        Prefix=prefix,
    ):
        for obj in page.get("Contents", []):
            if obj["Key"].endswith("/"):
                continue

            yield obj


def build_file_record(interface, family, bucket, obj):
    return {
        "interface": interface,
        "family": family,
        "bucket": bucket,
        "key": obj["Key"],
        "filename": object_basename(obj["Key"]),
        "size": obj["Size"],
        "last_modified": obj["LastModified"],
    }


def find_missing_parts(part_numbers):
    if not part_numbers:
        return []

    highest_part = max(part_numbers)

    expected_parts = set(
        range(1, highest_part + 1)
    )

    actual_parts = set(part_numbers)

    return sorted(
        expected_parts - actual_parts
    )


def format_parts(part_numbers, max_display=20):
    part_numbers = sorted(part_numbers)

    if len(part_numbers) <= max_display:
        return ",".join(
            str(x)
            for x in part_numbers
        )

    first = ",".join(
        str(x)
        for x in part_numbers[:10]
    )

    last = ",".join(
        str(x)
        for x in part_numbers[-5:]
    )

    return (
        f"{first},...,{last} "
        f"({len(part_numbers)} total)"
    )


# =============================================================================
# AWS SESSION / IDENTITY
# =============================================================================

def create_session(profile, region):
    return boto3.Session(
        profile_name=profile,
        region_name=region,
    )


def mask_account(account_id):
    if not account_id or len(account_id) < 4:
        return "************"

    return "*" * (len(account_id) - 4) + account_id[-4:]


def show_identity(session, label):
    sts = session.client("sts")
    identity = sts.get_caller_identity()

    account_id = identity["Account"]
    masked_account = mask_account(account_id)

    masked_arn = identity["Arn"].replace(
        account_id,
        masked_account,
    )

    print("\n" + "=" * 100)

    print(
        ctext(
            label,
            Color.CYAN + Color.BOLD,
        )
    )

    print("=" * 100)
    print(f"Account : {masked_account}")
    print(f"ARN     : {masked_arn}")
    print("=" * 100)


# =============================================================================
# FLB DISCOVERY
# =============================================================================

def find_flb_files(s3, requested_date):
    ymd = requested_date.strftime("%Y%m%d")

    results = []
    missing = []

    print(
        "\n" +
        ctext(
            "Searching FLB PROD prefixes...",
            Color.CYAN + Color.BOLD,
        )
    )

    for family, prefix in FLB_PREFIXES.items():

        candidates = []

        regex = re.compile(
            rf"^{re.escape(family)}"
            rf"({ymd}\d{{6}})"
            rf"-(\d+)\.csv$",
            re.IGNORECASE,
        )

        for obj in list_objects(
            s3,
            FLB_BUCKET,
            prefix,
        ):
            filename = object_basename(
                obj["Key"]
            )

            match = regex.match(
                filename
            )

            if match:

                run_timestamp = (
                    match.group(1)
                )

                part_number = int(
                    match.group(2)
                )

                candidates.append(
                    {
                        "run_timestamp": run_timestamp,
                        "part_number": part_number,
                        "object": obj,
                    }
                )

        if not candidates:

            print(
                ctext(
                    f"  {family:<25} MISSING",
                    Color.YELLOW,
                )
            )

            missing.append(
                f"FLB/{family}"
            )

            continue

        latest_timestamp = max(
            item["run_timestamp"]
            for item in candidates
        )

        selected = [
            item
            for item in candidates
            if item["run_timestamp"]
            == latest_timestamp
        ]

        selected.sort(
            key=lambda item:
            item["part_number"]
        )

        part_numbers = [
            item["part_number"]
            for item in selected
        ]

        missing_parts = (
            find_missing_parts(
                part_numbers
            )
        )

        print(
            f"  {family:<25} "
            f"{ctext(str(len(selected)), Color.GREEN)} "
            f"file(s) "
            f"[run {latest_timestamp}] "
            f"[parts: {format_parts(part_numbers)}]"
        )

        if missing_parts:

            print(
                ctext(
                    f"    WARNING: Missing part(s): "
                    f"{','.join(map(str, missing_parts))}",
                    Color.YELLOW + Color.BOLD,
                )
            )

            missing.append(
                f"FLB/{family} "
                f"missing part(s): "
                f"{','.join(map(str, missing_parts))}"
            )

        for item in selected:

            results.append(
                build_file_record(
                    "FLB",
                    family,
                    FLB_BUCKET,
                    item["object"],
                )
            )

    return results, missing


# =============================================================================
# SFDM DISCOVERY
# =============================================================================

def find_sfdm_files(s3, requested_date):
    ymd = requested_date.strftime("%Y%m%d")

    results = []
    missing = []

    print(
        "\n" +
        ctext(
            "Searching SFDM PROD prefixes...",
            Color.CYAN + Color.BOLD,
        )
    )

    objects = list(
        list_objects(
            s3,
            SFDM_BUCKET,
            SFDM_ROOT_PREFIX,
        )
    )

    for family in SFDM_FAMILIES:

        candidates = []

        regex = re.compile(
            rf"^CpsToSF-qy-compass-"
            rf"{re.escape(family)}-"
            rf"({ymd}\d{{6}})"
            rf"-part(\d+)\.csv$",
            re.IGNORECASE,
        )

        for obj in objects:

            filename = object_basename(
                obj["Key"]
            )

            match = regex.match(
                filename
            )

            if match:

                run_timestamp = (
                    match.group(1)
                )

                part_number = int(
                    match.group(2)
                )

                candidates.append(
                    {
                        "run_timestamp": run_timestamp,
                        "part_number": part_number,
                        "object": obj,
                    }
                )

        if not candidates:

            print(
                ctext(
                    f"  {family:<30} MISSING",
                    Color.YELLOW,
                )
            )

            missing.append(
                f"SFDM/{family}"
            )

            continue

        latest_timestamp = max(
            item["run_timestamp"]
            for item in candidates
        )

        selected = [
            item
            for item in candidates
            if item["run_timestamp"]
            == latest_timestamp
        ]

        selected.sort(
            key=lambda item:
            item["part_number"]
        )

        part_numbers = [
            item["part_number"]
            for item in selected
        ]

        missing_parts = (
            find_missing_parts(
                part_numbers
            )
        )

        print(
            f"  {family:<30} "
            f"{ctext(str(len(selected)), Color.GREEN)} "
            f"file(s) "
            f"[run {latest_timestamp}] "
            f"[parts: {format_parts(part_numbers)}]"
        )

        if missing_parts:

            print(
                ctext(
                    f"    WARNING: Missing part(s): "
                    f"{','.join(map(str, missing_parts))}",
                    Color.YELLOW + Color.BOLD,
                )
            )

            missing.append(
                f"SFDM/{family} "
                f"missing part(s): "
                f"{','.join(map(str, missing_parts))}"
            )

        for item in selected:

            results.append(
                build_file_record(
                    "SFDM",
                    family,
                    SFDM_BUCKET,
                    item["object"],
                )
            )

    return results, missing


# =============================================================================
# DATAPLATFORM DISCOVERY
# =============================================================================

def find_dataplatform_files(
    s3,
    requested_date,
):
    ymd = requested_date.strftime(
        "%Y%m%d"
    )

    results = []
    missing = []

    print(
        "\n" +
        ctext(
            "Searching DataPlatform PROD prefix...",
            Color.CYAN + Color.BOLD,
        )
    )

    objects = list(
        list_objects(
            s3,
            DATAPLATFORM_BUCKET,
            DATAPLATFORM_PREFIX,
        )
    )

    for family in DATAPLATFORM_FAMILIES:

        regex = re.compile(
            rf"^{re.escape(family)}"
            rf"_dataplatform-"
            rf"{ymd}-"
            rf"(\d{{6}})\.csv$",
            re.IGNORECASE,
        )

        candidates = []

        for obj in objects:

            filename = object_basename(
                obj["Key"]
            )

            match = regex.match(
                filename
            )

            if match:

                candidates.append(
                    (
                        match.group(1),
                        obj,
                    )
                )

        if not candidates:

            print(
                ctext(
                    f"  {family:<30} MISSING",
                    Color.YELLOW,
                )
            )

            missing.append(
                f"DATAPLATFORM/{family}"
            )

            continue

        latest_time, latest_obj = max(
            candidates,
            key=lambda x: x[0],
        )

        print(
            f"  {family:<30} "
            f"{ctext('[FOUND]', Color.GREEN)} "
            f"[time {latest_time}]"
        )

        results.append(
            build_file_record(
                "DATAPLATFORM",
                family,
                DATAPLATFORM_BUCKET,
                latest_obj,
            )
        )

    ack_regex = re.compile(
        rf"^Compass_Extract-FR-"
        rf"{ymd}-"
        rf"(\d{{6}})\.ack$",
        re.IGNORECASE,
    )

    ack_candidates = []

    for obj in objects:

        filename = object_basename(
            obj["Key"]
        )

        match = ack_regex.match(
            filename
        )

        if match:

            ack_candidates.append(
                (
                    match.group(1),
                    obj,
                )
            )

    if ack_candidates:

        latest_time, latest_obj = max(
            ack_candidates,
            key=lambda x: x[0],
        )

        print(
            f"  {'Compass_Extract-FR ACK':<30} "
            f"{ctext('[FOUND]', Color.GREEN)} "
            f"[time {latest_time}]"
        )

        results.append(
            build_file_record(
                "DATAPLATFORM",
                "Compass_Extract-FR ACK",
                DATAPLATFORM_BUCKET,
                latest_obj,
            )
        )

    else:

        print(
            ctext(
                f"  {'Compass_Extract-FR ACK':<30} "
                f"MISSING",
                Color.YELLOW,
            )
        )

        missing.append(
            "DATAPLATFORM/"
            "Compass_Extract-FR ACK"
        )

    return results, missing


# =============================================================================
# WPO DISCOVERY
# =============================================================================

def find_wpo_files(s3):

    results = []
    missing = []

    print(
        "\n" +
        ctext(
            "Searching WPO PROD prefix...",
            Color.CYAN + Color.BOLD,
        )
    )

    objects = list(
        list_objects(
            s3,
            WPO_BUCKET,
            WPO_PREFIX,
        )
    )

    for family, pattern in (
        WPO_PATTERNS.items()
    ):

        candidates = []

        for obj in objects:

            filename = object_basename(
                obj["Key"]
            )

            if fnmatch.fnmatchcase(
                filename.lower(),
                pattern.lower(),
            ):

                candidates.append(
                    obj
                )

        if not candidates:

            print(
                ctext(
                    f"  {family:<25} "
                    f"MISSING ({pattern})",
                    Color.YELLOW,
                )
            )

            missing.append(
                f"WPO/{family}"
            )

            continue

        latest_obj = max(
            candidates,
            key=lambda x:
            x["LastModified"],
        )

        filename = object_basename(
            latest_obj["Key"]
        )

        print(
            f"  {family:<25} "
            f"{ctext(filename, Color.GREEN)}"
        )

        print(
            f"  {'':<25} "
            f"LastModified: "
            f"{latest_obj['LastModified']}"
        )

        results.append(
            build_file_record(
                "WPO",
                family,
                WPO_BUCKET,
                latest_obj,
            )
        )

    return results, missing


# =============================================================================
# MANIFEST DISPLAY
# =============================================================================

def display_manifest(files, missing):

    print(
        "\n" + "=" * 110
    )

    print(
        ctext(
            "PROD FILES SELECTED",
            Color.CYAN + Color.BOLD,
        )
    )

    print("=" * 110)

    grouped = defaultdict(
        list
    )

    for item in files:

        grouped[
            (
                item["interface"],
                item["family"],
            )
        ].append(
            item
        )

    total_size = 0

    for interface, family in sorted(
        grouped
    ):

        items = grouped[
            (
                interface,
                family,
            )
        ]

        print(
            "\n" +
            ctext(
                f"[{interface} - {family}]",
                Color.CYAN,
            )
        )

        print("-" * 110)

        for item in items:

            print(
                ctext(
                    item["filename"],
                    Color.GREEN,
                )
            )

            source_path = (
                f"s3://"
                f"{item['bucket']}/"
                f"{item['key']}"
            )

            print(
                f"  Source       : "
                f"{ctext(source_path, Color.BLUE)}"
            )

            print(
                f"  Size         : "
                f"{human_size(item['size'])}"
            )

            print(
                f"  LastModified : "
                f"{item['last_modified']}"
            )

            total_size += (
                item["size"]
            )

    print(
        "\n" + "=" * 110
    )

    print(
        f"TOTAL FILES : "
        f"{ctext(str(len(files)), Color.GREEN + Color.BOLD)}"
    )

    print(
        f"TOTAL SIZE  : "
        f"{ctext(human_size(total_size), Color.GREEN + Color.BOLD)}"
    )

    if missing:

        print(
            ctext(
                "\nWARNING - ITEMS REQUIRING REVIEW:",
                Color.YELLOW + Color.BOLD,
            )
        )

        for item in missing:

            print(
                ctext(
                    f"  - {item}",
                    Color.YELLOW,
                )
            )

    else:

        print(
            ctext(
                "\nAll configured feeds were found.",
                Color.GREEN + Color.BOLD,
            )
        )

    print("=" * 110)


# =============================================================================
# DOWNLOAD
# =============================================================================

def download_files(
    s3,
    files,
    staging_root,
):

    downloaded = []

    print(
        "\n" +
        ctext(
            "Downloading selected PROD files...",
            Color.CYAN + Color.BOLD,
        )
    )

    for index, item in enumerate(
        files,
        start=1,
    ):

        local_directory = (
            staging_root
            / item["interface"].lower()
        )

        local_directory.mkdir(
            parents=True,
            exist_ok=True,
        )

        local_path = (
            local_directory
            / item["filename"]
        )

        print(
            f"[{index}/{len(files)}] "
            f"{item['interface']} - "
            f"{item['filename']}"
        )

        s3.download_file(
            item["bucket"],
            item["key"],
            str(local_path),
        )

        local_size = (
            local_path.stat().st_size
        )

        if local_size != item["size"]:

            raise RuntimeError(
                f"DOWNLOAD SIZE MISMATCH: "
                f"{item['filename']} "
                f"PROD={item['size']} "
                f"LOCAL={local_size}"
            )

        print(
            ctext(
                "    Download validated",
                Color.GREEN,
            )
        )

        downloaded.append(
            {
                **item,
                "local_path": local_path,
            }
        )

    return downloaded


def display_download_summary(
    downloaded,
):

    print(
        "\n" + "=" * 100
    )

    print(
        ctext(
            "LOCAL DOWNLOAD VALIDATION",
            Color.CYAN + Color.BOLD,
        )
    )

    print("=" * 100)

    total_size = 0

    for index, item in enumerate(
        downloaded,
        start=1,
    ):

        local_size = (
            item["local_path"]
            .stat()
            .st_size
        )

        print(
            f"{index:03d}. "
            f"{ctext('[PASS]', Color.GREEN + Color.BOLD)} "
            f"[{item['interface']}] "
            f"{item['filename']} "
            f"({human_size(local_size)})"
        )

        total_size += (
            local_size
        )

    print(
        "\n" + "-" * 100
    )

    print(
        f"DOWNLOADED FILES : "
        f"{ctext(str(len(downloaded)), Color.GREEN + Color.BOLD)}"
    )

    print(
        f"DOWNLOADED SIZE  : "
        f"{ctext(human_size(total_size), Color.GREEN + Color.BOLD)}"
    )

    print("=" * 100)


# =============================================================================
# UAT UPLOAD
# =============================================================================

def upload_files(
    uat_s3,
    downloaded,
):

    uploaded = []

    print(
        "\n" +
        ctext(
            "Uploading selected files to UAT...",
            Color.CYAN + Color.BOLD,
        )
    )

    for index, item in enumerate(
        downloaded,
        start=1,
    ):

        destination_prefix = (
            UAT_PREFIXES[
                item["interface"]
            ]
        )

        destination_key = (
            destination_prefix
            + item["filename"]
        )

        print(
            f"[{index}/{len(downloaded)}] "
            f"{item['filename']}"
        )

        destination_path = (
            f"s3://"
            f"{UAT_BUCKET}/"
            f"{destination_key}"
        )

        print(
            f"    -> "
            f"{ctext(destination_path, Color.BLUE)}"
        )

        uat_s3.upload_file(
            str(item["local_path"]),
            UAT_BUCKET,
            destination_key,
        )

        uploaded.append(
            {
                **item,
                "destination_bucket":
                    UAT_BUCKET,
                "destination_key":
                    destination_key,
            }
        )

    return uploaded


# =============================================================================
# UAT VALIDATION
# =============================================================================

def validate_uploads(
    uat_s3,
    uploaded,
):

    print(
        "\n" + "=" * 110
    )

    print(
        ctext(
            "UAT UPLOAD VALIDATION",
            Color.CYAN + Color.BOLD,
        )
    )

    print("=" * 110)

    passed = []
    failed = []

    for index, item in enumerate(
        uploaded,
        start=1,
    ):

        try:

            response = (
                uat_s3.head_object(
                    Bucket=UAT_BUCKET,
                    Key=item[
                        "destination_key"
                    ],
                )
            )

            destination_size = (
                response[
                    "ContentLength"
                ]
            )

            source_size = (
                item["size"]
            )

            if (
                destination_size
                == source_size
            ):

                status = ctext(
                    "PASS",
                    Color.GREEN
                    + Color.BOLD,
                )

                passed.append(
                    item
                )

            else:

                status = ctext(
                    "SIZE MISMATCH",
                    Color.RED
                    + Color.BOLD,
                )

                failed.append(
                    item
                )

            print(
                f"{index:03d}. "
                f"[{status}] "
                f"[{item['interface']}] "
                f"{item['filename']}"
            )

            print(
                f"     PROD: "
                f"{human_size(source_size)}"
            )

            print(
                f"     UAT : "
                f"{human_size(destination_size)}"
            )

        except Exception as exc:

            failed.append(
                item
            )

            print(
                f"{index:03d}. "
                f"{ctext('[FAIL]', Color.RED + Color.BOLD)} "
                f"{item['filename']}"
            )

            print(
                ctext(
                    f"     {exc}",
                    Color.RED,
                )
            )

    print(
        "\n" + "=" * 110
    )

    print(
        f"EXPECTED : "
        f"{len(uploaded)}"
    )

    print(
        f"PASSED   : "
        f"{ctext(str(len(passed)), Color.GREEN + Color.BOLD)}"
    )

    failed_color = (
        Color.GREEN + Color.BOLD
        if len(failed) == 0
        else Color.RED + Color.BOLD
    )

    print(
        f"FAILED   : "
        f"{ctext(str(len(failed)), failed_color)}"
    )

    print("=" * 110)

    if failed:

        print(
            ctext(
                "\nFAILED OBJECTS:",
                Color.RED
                + Color.BOLD,
            )
        )

        for item in failed:

            print(
                ctext(
                    f"  - "
                    f"[{item['interface']}] "
                    f"{item['filename']}",
                    Color.RED,
                )
            )

        return False

    return True


# =============================================================================
# UAT SUMMARY
# =============================================================================

def display_uat_summary(
    uat_s3,
    uploaded,
):

    grouped = defaultdict(
        list
    )

    for item in uploaded:

        grouped[
            item["interface"]
        ].append(
            item
        )

    print(
        "\n" + "=" * 110
    )

    print(
        ctext(
            "UAT FILE SUMMARY",
            Color.CYAN + Color.BOLD,
        )
    )

    print("=" * 110)

    total_verified = 0

    for interface in [
        "FLB",
        "SFDM",
        "DATAPLATFORM",
        "WPO",
    ]:

        items = grouped.get(
            interface,
            [],
        )

        print(
            "\n" +
            ctext(
                f"[{interface}]",
                Color.CYAN,
            )
        )

        print("-" * 110)

        verified = 0

        for item in items:

            try:

                response = (
                    uat_s3.head_object(
                        Bucket=UAT_BUCKET,
                        Key=item[
                            "destination_key"
                        ],
                    )
                )

                print(
                    f"  "
                    f"{ctext('[PASS]', Color.GREEN)} "
                    f"{item['filename']} "
                    f"("
                    f"{human_size(response['ContentLength'])}"
                    f")"
                )

                verified += 1

            except Exception:

                print(
                    ctext(
                        f"  [MISSING] "
                        f"{item['filename']}",
                        Color.RED,
                    )
                )

        print(
            f"\n{interface} VERIFIED: "
            f"{ctext(str(verified), Color.GREEN)}/"
            f"{len(items)}"
        )

        total_verified += (
            verified
        )

    print(
        "\n" + "=" * 110
    )

    print(
        f"TOTAL VERIFIED IN UAT: "
        f"{ctext(str(total_verified), Color.GREEN + Color.BOLD)}/"
        f"{len(uploaded)}"
    )

    print("=" * 110)


# =============================================================================
# MAIN
# =============================================================================

def main():

    global USE_COLOR

    parser = argparse.ArgumentParser(
        description=(
            "Compass PROD to UAT "
            "file transfer"
        )
    )

    parser.add_argument(
        "--date",
        required=True,
        help=(
            "QA processing date "
            "YYYY-MM-DD"
        ),
    )

    parser.add_argument(
        "--staging-dir",
        default="./compass_transfer",
        help="Local staging root",
    )

    parser.add_argument(
        "--no-color",
        action="store_true",
        help=(
            "Disable ANSI terminal "
            "colors"
        ),
    )

    args = parser.parse_args()

    if args.no_color:
        USE_COLOR = False

    try:

        requested_date = (
            datetime.strptime(
                args.date,
                "%Y-%m-%d",
            ).date()
        )

    except ValueError:

        print(
            ctext(
                "ERROR: --date must use "
                "YYYY-MM-DD format.",
                Color.RED + Color.BOLD,
            )
        )

        sys.exit(1)

    print(
        "\n" + "=" * 110
    )

    print(
        ctext(
            "COMPASS PARALLEL TESTING "
            "FILE TRANSFER",
            Color.CYAN + Color.BOLD,
        )
    )

    print("=" * 110)

    print(
        f"Processing date : "
        f"{requested_date}"
    )

    print(
        f"PROD profile    : "
        f"{PROD_PROFILE}"
    )

    print(
        f"PROD region     : "
        f"{PROD_REGION}"
    )

    print(
        f"UAT profile     : "
        f"{UAT_PROFILE}"
    )

    print(
        f"UAT region      : "
        f"{UAT_REGION}"
    )

    print(
        f"UAT bucket      : "
        f"{UAT_BUCKET}"
    )

    print("=" * 110)

    try:

        prod_session = (
            create_session(
                PROD_PROFILE,
                PROD_REGION,
            )
        )

        uat_session = (
            create_session(
                UAT_PROFILE,
                UAT_REGION,
            )
        )

        show_identity(
            prod_session,
            "PROD AWS IDENTITY",
        )

        show_identity(
            uat_session,
            "UAT AWS IDENTITY",
        )

    except Exception as exc:

        print(
            ctext(
                "\nERROR obtaining "
                "AWS identity.",
                Color.RED
                + Color.BOLD,
            )
        )

        print(
            ctext(
                str(exc),
                Color.RED,
            )
        )

        sys.exit(1)

    if not confirm(
        "Confirm these PROD and UAT "
        "AWS identities are correct?"
    ):

        print(
            ctext(
                "\nCancelled.",
                Color.YELLOW,
            )
        )

        sys.exit(0)

    prod_s3 = (
        prod_session.client(
            "s3"
        )
    )

    uat_s3 = (
        uat_session.client(
            "s3"
        )
    )

    # =========================================================================
    # DISCOVERY
    # =========================================================================

    try:

        files = []
        missing = []

        discovered, missed = (
            find_flb_files(
                prod_s3,
                requested_date,
            )
        )

        files.extend(
            discovered
        )

        missing.extend(
            missed
        )

        discovered, missed = (
            find_sfdm_files(
                prod_s3,
                requested_date,
            )
        )

        files.extend(
            discovered
        )

        missing.extend(
            missed
        )

        discovered, missed = (
            find_dataplatform_files(
                prod_s3,
                requested_date,
            )
        )

        files.extend(
            discovered
        )

        missing.extend(
            missed
        )

        discovered, missed = (
            find_wpo_files(
                prod_s3,
            )
        )

        files.extend(
            discovered
        )

        missing.extend(
            missed
        )

    except Exception as exc:

        print(
            ctext(
                "\nERROR while searching "
                "PROD S3.",
                Color.RED
                + Color.BOLD,
            )
        )

        print(
            ctext(
                str(exc),
                Color.RED,
            )
        )

        sys.exit(1)

    files.sort(
        key=lambda item: (
            item["interface"],
            item["family"],
            item["filename"],
        )
    )

    display_manifest(
        files,
        missing,
    )

    if not files:

        print(
            ctext(
                "\nNo files were selected. "
                "Nothing to transfer.",
                Color.RED
                + Color.BOLD,
            )
        )

        sys.exit(1)

    if missing:

        print(
            ctext(
                "\nWARNING: One or more "
                "items require review.",
                Color.YELLOW
                + Color.BOLD,
            )
        )

        print(
            ctext(
                "Review the warning list "
                "before continuing.",
                Color.YELLOW,
            )
        )

    if not confirm(
        "Proceed with downloading "
        "EXACTLY these files from PROD?"
    ):

        print(
            ctext(
                "\nCancelled before download.",
                Color.YELLOW,
            )
        )

        sys.exit(0)

    execution_timestamp = (
        datetime.now()
        .strftime(
            "%Y%m%d_%H%M%S"
        )
    )

    staging_root = (
        Path(
            args.staging_dir
        )
        / (
            f"{requested_date}_"
            f"{execution_timestamp}"
        )
    )

    # =========================================================================
    # DOWNLOAD
    # =========================================================================

    try:

        downloaded = (
            download_files(
                prod_s3,
                files,
                staging_root,
            )
        )

    except Exception as exc:

        print(
            ctext(
                "\nDOWNLOAD FAILED.",
                Color.RED
                + Color.BOLD,
            )
        )

        print(
            ctext(
                str(exc),
                Color.RED,
            )
        )

        print(
            f"\nStaging directory:"
            f"\n{staging_root}"
        )

        sys.exit(2)

    display_download_summary(
        downloaded
    )

    print(
        "\n" +
        ctext(
            "UAT destination mappings:",
            Color.CYAN + Color.BOLD,
        )
    )

    print(
        f"  FLB          -> "
        f"{ctext(f's3://{UAT_BUCKET}/cloud/flb/', Color.BLUE)}"
    )

    print(
        f"  SFDM         -> "
        f"{ctext(f's3://{UAT_BUCKET}/cloud/sfdm/', Color.BLUE)}"
    )

    print(
        f"  DataPlatform -> "
        f"{ctext(f's3://{UAT_BUCKET}/cloud/dataplatform/', Color.BLUE)}"
    )

    print(
        f"  WPO          -> "
        f"{ctext(f's3://{UAT_BUCKET}/cloud/wpo/', Color.BLUE)}"
    )

    if not confirm(
        "Downloads validated. "
        "Proceed with UAT upload?"
    ):

        print(
            ctext(
                "\nStopped before "
                "UAT upload.",
                Color.YELLOW,
            )
        )

        print(
            f"\nDownloaded files "
            f"remain in:"
            f"\n{staging_root}"
        )

        sys.exit(0)

    # =========================================================================
    # UPLOAD
    # =========================================================================

    try:

        uploaded = (
            upload_files(
                uat_s3,
                downloaded,
            )
        )

    except Exception as exc:

        print(
            ctext(
                "\nUAT UPLOAD FAILED.",
                Color.RED
                + Color.BOLD,
            )
        )

        print(
            ctext(
                str(exc),
                Color.RED,
            )
        )

        print(
            f"\nLocal files "
            f"remain in:"
            f"\n{staging_root}"
        )

        sys.exit(2)

    # =========================================================================
    # VALIDATION
    # =========================================================================

    validation_passed = (
        validate_uploads(
            uat_s3,
            uploaded,
        )
    )

    display_uat_summary(
        uat_s3,
        uploaded,
    )

    # =========================================================================
    # FINAL RESULT
    # =========================================================================

    if validation_passed:

        print(
            "\n" + "=" * 110
        )

        print(
            ctext(
                "TRANSFER COMPLETED "
                "SUCCESSFULLY",
                Color.GREEN
                + Color.BOLD,
            )
        )

        print("=" * 110)

        print(
            f"Transferred and validated: "
            f"{ctext(str(len(uploaded)), Color.GREEN + Color.BOLD)} "
            f"file(s)"
        )

        print(
            f"Local staging directory:"
            f"\n{staging_root}"
        )

        print("=" * 110)

        sys.exit(0)

    else:

        print(
            "\n" + "=" * 110
        )

        print(
            ctext(
                "TRANSFER COMPLETED WITH "
                "VALIDATION ERRORS",
                Color.RED
                + Color.BOLD,
            )
        )

        print("=" * 110)

        print(
            f"Local staging directory:"
            f"\n{staging_root}"
        )

        print("=" * 110)

        sys.exit(2)


if __name__ == "__main__":
    main()