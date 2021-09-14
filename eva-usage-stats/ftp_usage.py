#!/usr/bin/python
import os
from argparse import ArgumentParser
from datetime import datetime

import psycopg2.extras
import requests
from requests.auth import HTTPBasicAuth

from ebi_eva_common_pyutils.logger import logging_config
from ebi_eva_common_pyutils.metadata_utils import get_metadata_connection_handle
from ebi_eva_common_pyutils.pg_utils import get_all_results_for_query, execute_query
from retry import retry

logger = logging_config.get_logger(__name__)
logging_config.add_stdout_handler()


# TODO where to call this?
def create_stats_table(private_config_xml_file):
    with get_metadata_connection_handle('development', private_config_xml_file) as metadata_connection_handle:
        query_create_table = (
            'CREATE TABLE IF NOT EXISTS eva_web_srvc_stats.ftp_traffic '
            '(event_ts_txt TEXT, event_ts TIMESTAMP, host TEXT, uhost TEXT,'
            ' request_time TEXT, request_year INTEGER, request_ts TIMESTAMP'
            ' file_name TEXT, file_size INTEGER, transfer_time INTEGER,'
            ' transfer_type CHAR, direction CHAR, special_action CHAR(4), access_mode CHAR,'
            ' country CHAR(2), region TEXT, city TEXT, domain_name TEXT, isp TEXT, usage_type TEXT)'
        )
    execute_query(metadata_connection_handle, query_create_table)


def load_batch_to_table(batch, private_config_xml_file):
    logger.info(f'Loading {len(batch)} records...')
    rows = [(
        b['@timestamp'],  # event timestamp
        b['@timestamp'],  # TODO conversion
        b['host'],  # webprod host
        b['uhost'],  # unique user host string
        # FTP log fields: see https://docs.oracle.com/cd/E19683-01/817-0667/6mgevq0ee/index.html
        b['current_time'],
        b['year'],
        b['current_time'] + b['year'],  # TODO conversion
        b['file_name'],
        b['file_size'],
        b['transfer_time'],
        b['transfer_type'],
        b['direction'],
        b['special_action'],
        b['access_mode'],
        # IP2Location fields: see https://www.ip2location.com/web-service/ip2location
        b['ip2location']['country_short'],
        b['ip2location']['region'],
        b['ip2location']['city'],
        b['ip2location']['domain'],
        b['ip2location']['isp'],
        b['ip2location']['usage_type'],
    ) for b in batch]
    with get_metadata_connection_handle('development', private_config_xml_file) as metadata_connection_handle:
        with metadata_connection_handle.cursor() as cursor:
            query_insert = (
                'INSERT INTO eva_web_srvc_stats.ftp_traffic '
                '(event_ts_txt, event_ts, host, uhost,'
                ' request_time, request_year, request_ts,'
                ' file_name, file_size, transfer_time,'
                ' transfer_type, direction, special_action, access_mode,'
                ' country, region, city, domain_name, isp, usage_type)'
                'VALUES %s'
            )
            psycopg2.extras.execute_values(cursor, query_insert, rows)


def get_most_recent_timestamp(private_config_xml_file):
    with get_metadata_connection_handle('development', private_config_xml_file) as metadata_connection_handle:
        results = get_all_results_for_query(
            metadata_connection_handle,
            "select max(event_ts_txt) as recent_ts from eva_web_srvc_stats.ftp_traffic;"
        )
        if results and results[0][0]:
            return results[0][0]
    return None


@retry(tries=4, delay=2, backoff=1.2, jitter=(1, 3))
def query(kibana_host, basic_auth, private_config_xml_file):
    first_query_url = os.path.join(kibana_host, 'ftplogs*/_search?scroll=24h')
    query_conditions = [{'query_string': {'query': 'file_name:("/pub/databases/eva/")'}}]
    most_recent_timestamp = get_most_recent_timestamp(private_config_xml_file)
    if most_recent_timestamp:
        query_conditions.append({'range': {'@timestamp': {'gt': most_recent_timestamp}}})
    post_query = {
        'size': '1000',  # scroll through data in chunks of 1000
        'query': {'bool': {'must': query_conditions}}
    }

    response = requests.post(first_query_url, auth=basic_auth, json=post_query)
    response.raise_for_status()
    data = response.json()
    total = data['hits']['total']
    if total == 0:
        logger.info('No results found')
        return

    scroll_id = data['_scroll_id']
    first_batch = data['hits']['hits']
    return scroll_id, total, first_batch


@retry(tries=4, delay=2, backoff=1.2, jitter=(1, 3))
def scroll(kibana_host, basic_auth, scroll_id):
    query_url = os.path.join(kibana_host, '_search/scroll')
    response = requests.post(query_url, auth=basic_auth, json={'scroll': '24h', 'scroll_id': scroll_id})
    response.raise_for_status()
    data = response.json()
    batch = data['hits']['hits']
    return batch


def main():
    parser = ArgumentParser(description='Retrieves data from Kibana and dumps into a local postgres instance')
    parser.add_argument('--kibana-host', help='Kibana host to query, e.g. http://example.ebi.ac.uk:9200', required=True)
    parser.add_argument('--kibana-user', help='Kibana API username', required=True)
    parser.add_argument('--kibana-pass', help='Kibana API password', required=True)
    parser.add_argument('--private-config-xml-file', help='ex: /path/to/eva-maven-settings.xml', required=True)
    args = parser.parse_args()

    kibana_host = args.kibana_host
    basic_auth = HTTPBasicAuth(args.kibana_user, args.kibana_pass)
    private_config_xml_file = args.private_config_xml_file

    loaded_so_far = 0
    scroll_id, total, batch = query(kibana_host, basic_auth, private_config_xml_file)
    load_batch_to_table(batch, private_config_xml_file)
    loaded_so_far += len(batch)

    while loaded_so_far < total:
        batch = scroll(kibana_host, basic_auth, scroll_id)
        load_batch_to_table(batch, private_config_xml_file)
        loaded_so_far += len(batch)

    logger.info(f'Done. Loaded {loaded_so_far} total records.')


if __name__ == '__main__':
    main()
