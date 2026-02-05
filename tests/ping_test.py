#!/usr/bin/env python3
"""
Standalone test runner for AHTSE tile server endpoint availability.

This script can be run independently of pytest to quickly check if tile endpoints
are accessible. It discovers all configured endpoints and tests basic connectivity.
"""

import sys
import os
import time
import json
from typing import List, Dict, Tuple
from concurrent.futures import ThreadPoolExecutor, as_completed

# Add current directory to path to import utils
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

try:
    import requests
    from requests.adapters import HTTPAdapter
    from urllib3.util.retry import Retry
    from urllib3 import disable_warnings
    from urllib3.exceptions import InsecureRequestWarning
    
    # Disable SSL warnings for testing
    disable_warnings(InsecureRequestWarning)
    
except ImportError:
    print("Error: requests library is required. Install with: pip install requests")
    sys.exit(1)

from utils import WebconfParser, TileEndpointGenerator, get_server_url, get_webconf_root, detect_server_url


class TileServerPingTest:
    """Standalone ping test for tile server endpoints."""
    
    def __init__(self, server_url: str = None, webconf_root: str = None):
        """Initialize the ping test."""
        self.base_server_url = server_url or get_server_url()
        self.webconf_root = webconf_root or get_webconf_root()
        
        # Try to detect the actual server URL (handles redirects)
        try:
            self.server_url = detect_server_url(self.base_server_url)
            if self.server_url != self.base_server_url:
                print(f"Server auto-detected: {self.base_server_url} -> {self.server_url}")
        except:
            self.server_url = self.base_server_url
        
        self.parser = WebconfParser(self.webconf_root)
        self.generator = TileEndpointGenerator(self.server_url)
        
        # Setup HTTP session with redirect handling
        self.session = requests.Session()
        retry_strategy = Retry(
            total=2,
            backoff_factor=0.5,
            status_forcelist=[429, 500, 502, 503, 504],
        )
        adapter = HTTPAdapter(max_retries=retry_strategy)
        self.session.mount("http://", adapter)
        self.session.mount("https://", adapter)
        
        # Allow redirects by default
        self.session.max_redirects = 3
        
        self.timeout = 15
        
    def ping_endpoint(self, endpoint_info: Dict) -> Dict:
        """
        Ping a single endpoint with multiple tile requests.
        
        Args:
            endpoint_info: Endpoint configuration from parser
            
        Returns:
            Dictionary with test results
        """
        name = endpoint_info['name']
        rel_dir = endpoint_info.get('relative_dir', '')
        
        result = {
            'name': name,
            'relative_dir': rel_dir,
            'status': 'unknown',
            'successful_tiles': 0,
            'failed_tiles': 0,
            'response_times': [],
            'errors': [],
            'tile_details': [],
            'sample_urls': []  # Add sample URLs for debugging
        }
        
        # Test coordinates - specific tiles requested
        test_coordinates = [
            (0, 0, 0),  # Zoom 0, tile 0,0
            (1, 0, 0),  # Zoom 1, tile 0,0
            (2, 1, 1),  # Zoom 2, tile 1,1
        ]
        
        for z, x, y in test_coordinates:
            tile_url = self.generator.generate_tile_url(endpoint_info, z, x, y)
            result['sample_urls'].append(tile_url)  # Store for debugging
            
            try:
                start_time = time.time()
                response = self.session.get(tile_url, timeout=self.timeout, allow_redirects=True)
                response_time = time.time() - start_time
                
                tile_detail = {
                    'coordinates': f"Z{z}X{x}Y{y}",
                    'url': tile_url,
                    'status_code': response.status_code,
                    'response_time': response_time,
                    'content_length': len(response.content) if response.content else 0
                }
                
                # Check if we were redirected
                if response.url != tile_url:
                    tile_detail['redirected_to'] = response.url
                
                if response.status_code == 200:
                    # Check if it's actually an image or valid response
                    content_type = response.headers.get('content-type', '')
                    if 'image' in content_type.lower() or response.content:
                        result['successful_tiles'] += 1
                        result['response_times'].append(response_time)
                        tile_detail['content_type'] = content_type
                    else:
                        result['failed_tiles'] += 1
                        result['errors'].append(f"Z{z}X{x}Y{y}: Empty or invalid content (content-type: {content_type})")
                        tile_detail['error'] = f"Empty or invalid content: {content_type}"
                elif response.status_code == 404:
                    # 404 might be expected for some tiles
                    tile_detail['note'] = "Not found (might be expected)"
                else:
                    result['failed_tiles'] += 1
                    result['errors'].append(f"Z{z}X{x}Y{y}: HTTP {response.status_code}")
                    tile_detail['error'] = f"HTTP {response.status_code}"
                    
                result['tile_details'].append(tile_detail)
                
            except requests.exceptions.Timeout:
                result['failed_tiles'] += 1
                error_msg = f"Z{z}X{x}Y{y}: Request timeout"
                result['errors'].append(error_msg)
                result['tile_details'].append({
                    'coordinates': f"Z{z}X{x}Y{y}",
                    'url': tile_url,
                    'error': "Timeout"
                })
            except requests.exceptions.RequestException as e:
                result['failed_tiles'] += 1
                error_msg = f"Z{z}X{x}Y{y}: {str(e)}"
                result['errors'].append(error_msg)
                result['tile_details'].append({
                    'coordinates': f"Z{z}X{x}Y{y}",
                    'url': tile_url,
                    'error': str(e)
                })
                
        # Determine overall status
        if result['successful_tiles'] > 0:
            if result['failed_tiles'] == 0:
                result['status'] = 'healthy'
            else:
                result['status'] = 'partial'
        else:
            result['status'] = 'failed'
            
        # Calculate average response time
        if result['response_times']:
            result['avg_response_time'] = sum(result['response_times']) / len(result['response_times'])
        else:
            result['avg_response_time'] = None
            
        return result
        
    def ping_all_endpoints(self, max_workers: int = 5) -> List[Dict]:
        """
        Ping all discovered endpoints concurrently.
        
        Args:
            max_workers: Maximum number of concurrent requests
            
        Returns:
            List of test results for all endpoints
        """
        endpoints = self.parser.discover_all_endpoints()
        
        if not endpoints:
            print("No endpoints discovered from webconf files.")
            return []
            
        print(f"Discovered {len(endpoints)} endpoints, testing with {max_workers} concurrent requests...")
        
        results = []
        
        with ThreadPoolExecutor(max_workers=max_workers) as executor:
            # Submit all ping tasks
            future_to_endpoint = {
                executor.submit(self.ping_endpoint, endpoint): endpoint 
                for endpoint in endpoints
            }
            
            # Collect results as they complete
            for future in as_completed(future_to_endpoint):
                endpoint = future_to_endpoint[future]
                try:
                    result = future.result()
                    results.append(result)
                    
                    # Print immediate feedback
                    status_symbol = {
                        'healthy': '✓',
                        'partial': '⚠',
                        'failed': '✗',
                        'unknown': '?'
                    }.get(result['status'], '?')
                    
                    print(f"{status_symbol} {result['name']} ({result['relative_dir']}) - {result['status']}")
                    
                except Exception as e:
                    error_result = {
                        'name': endpoint.get('name', 'unknown'),
                        'relative_dir': endpoint.get('relative_dir', ''),
                        'status': 'error',
                        'errors': [f"Test execution failed: {str(e)}"],
                        'successful_tiles': 0,
                        'failed_tiles': 0
                    }
                    results.append(error_result)
                    print(f"✗ {endpoint.get('name', 'unknown')} - Error: {e}")
                    
        return results
        
    def print_summary(self, results: List[Dict]):
        """Print a summary of test results."""
        if not results:
            print("\nNo results to summarize.")
            return
            
        healthy_count = sum(1 for r in results if r['status'] == 'healthy')
        partial_count = sum(1 for r in results if r['status'] == 'partial')
        failed_count = sum(1 for r in results if r['status'] == 'failed')
        error_count = sum(1 for r in results if r['status'] == 'error')
        
        total_successful_tiles = sum(r['successful_tiles'] for r in results)
        total_failed_tiles = sum(r['failed_tiles'] for r in results)
        
        print(f"\n{'='*60}")
        print("TILE SERVER PING TEST SUMMARY")
        print(f"{'='*60}")
        print(f"Base Server URL: {self.base_server_url}")
        if self.server_url != self.base_server_url:
            print(f"Detected Server URL: {self.server_url}")
        print(f"Total Endpoints: {len(results)}")
        print(f"  ✓ Healthy: {healthy_count}")
        print(f"  ⚠ Partial: {partial_count}")
        print(f"  ✗ Failed: {failed_count}")
        print(f"  ? Error: {error_count}")
        print(f"")
        print(f"Total Tiles Tested: {total_successful_tiles + total_failed_tiles}")
        print(f"  Successful: {total_successful_tiles}")
        print(f"  Failed: {total_failed_tiles}")
        
        # Show sample URLs for debugging
        if results:
            print(f"\nSample URLs tested:")
            for result in results:  # Show all endpoints
                if result.get('sample_urls'):
                    print(f"  {result['name']} ({result['relative_dir']}):")
                    for url in result['sample_urls']:  # Show all URLs
                        print(f"    {url}")
        
        # Show all endpoints tested
        print(f"\n{'='*60}")
        print("ALL ENDPOINTS TESTED")
        print(f"{'='*60}")
        
        for result in results:
            status_symbol = {
                'healthy': '✓',
                'partial': '⚠',
                'failed': '✗',
                'error': '?'
            }.get(result['status'], '?')
            
            print(f"{status_symbol} {result['name']} ({result['relative_dir']}) - {result['status'].upper()}")
            print(f"    Successful: {result['successful_tiles']}, Failed: {result['failed_tiles']}")
            if result.get('avg_response_time'):
                print(f"    Avg Response Time: {result['avg_response_time']:.3f}s")
            if result.get('errors'):
                print(f"    Errors: {len(result['errors'])}")
            print()
        
        # Show detailed results for failed/partial endpoints
        problem_endpoints = [r for r in results if r['status'] in ['failed', 'partial', 'error']]
        if problem_endpoints:
            print(f"{'='*60}")
            print("DETAILED RESULTS FOR PROBLEM ENDPOINTS")
            print(f"{'='*60}")
            
            for result in problem_endpoints:
                print(f"\nEndpoint: {result['name']} ({result['relative_dir']})")
                print(f"Status: {result['status'].upper()}")
                print(f"Successful tiles: {result['successful_tiles']}")
                print(f"Failed tiles: {result['failed_tiles']}")
                
                if result.get('avg_response_time'):
                    print(f"Avg response time: {result['avg_response_time']:.3f}s")
                
                if result.get('sample_urls'):
                    print(f"Sample URLs:")
                    for url in result['sample_urls'][:2]:
                        print(f"  {url}")
                
                if result.get('errors'):
                    print("Errors:")
                    for error in result['errors']:
                        print(f"  - {error}")
                        
        # Show performance summary for healthy endpoints
        healthy_endpoints = [r for r in results if r['status'] == 'healthy' and r.get('avg_response_time')]
        if healthy_endpoints:
            print(f"{'='*60}")
            print("PERFORMANCE SUMMARY (HEALTHY ENDPOINTS)")
            print(f"{'='*60}")
            
            for result in sorted(healthy_endpoints, key=lambda x: x['avg_response_time']):
                print(f"{result['name']}: {result['avg_response_time']:.3f}s avg")
                
    def save_detailed_report(self, results: List[Dict], filename: str = None):
        """Save detailed results to JSON file."""
        if filename is None:
            timestamp = time.strftime("%Y%m%d_%H%M%S")
            filename = f"tile_server_ping_report_{timestamp}.json"
            
        report = {
            'timestamp': time.time(),
            'server_url': self.server_url,
            'webconf_root': self.webconf_root,
            'summary': {
                'total_endpoints': len(results),
                'healthy': sum(1 for r in results if r['status'] == 'healthy'),
                'partial': sum(1 for r in results if r['status'] == 'partial'),
                'failed': sum(1 for r in results if r['status'] == 'failed'),
                'error': sum(1 for r in results if r['status'] == 'error'),
                'total_successful_tiles': sum(r['successful_tiles'] for r in results),
                'total_failed_tiles': sum(r['failed_tiles'] for r in results),
            },
            'endpoint_results': results
        }
        
        try:
            with open(filename, 'w') as f:
                json.dump(report, f, indent=2)
            print(f"\nDetailed report saved to: {filename}")
        except Exception as e:
            print(f"\nWarning: Could not save report to {filename}: {e}")


def main():
    """Main entry point for standalone execution."""
    import argparse
    
    parser = argparse.ArgumentParser(
        description="Test AHTSE tile server endpoint availability",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  python ping_test.py                                    # Test with default settings
  python ping_test.py --server http://localhost:8080    # Custom server URL
  python ping_test.py --save-report                     # Save detailed JSON report
  python ping_test.py --workers 10                      # Use more concurrent requests
        """
    )
    
    parser.add_argument(
        '--server', 
        default=None,
        help='Server base URL (default: http://localhost or TILE_SERVER_URL env var)'
    )
    parser.add_argument(
        '--webconf', 
        default=None,
        help='Path to webconf directory (default: ../webconf relative to script)'
    )
    parser.add_argument(
        '--workers',
        type=int,
        default=5,
        help='Number of concurrent workers (default: 5)'
    )
    parser.add_argument(
        '--save-report',
        action='store_true',
        help='Save detailed JSON report'
    )
    parser.add_argument(
        '--auto-detect',
        action='store_true',
        default=True,
        help='Auto-detect server URL by testing common ports (default: enabled)'
    )
    parser.add_argument(
        '--no-auto-detect',
        action='store_true', 
        help='Disable auto-detection and use exact server URL specified'
    )
    parser.add_argument(
        '--quiet',
        action='store_true', 
        help='Only show summary, not individual endpoint status'
    )
    
    args = parser.parse_args()
    
    # Initialize test runner
    base_server_url = args.server
    if args.no_auto_detect:
        # Use exact URL without auto-detection
        test_runner = TileServerPingTest.__new__(TileServerPingTest)
        test_runner.base_server_url = base_server_url or get_server_url()
        test_runner.server_url = test_runner.base_server_url
        test_runner.webconf_root = args.webconf or get_webconf_root()
        test_runner.parser = WebconfParser(test_runner.webconf_root)
        test_runner.generator = TileEndpointGenerator(test_runner.server_url)
        
        # Setup session
        test_runner.session = requests.Session()
        retry_strategy = Retry(total=2, backoff_factor=0.5, status_forcelist=[429, 500, 502, 503, 504])
        adapter = HTTPAdapter(max_retries=retry_strategy)
        test_runner.session.mount("http://", adapter)
        test_runner.session.mount("https://", adapter)
        test_runner.timeout = 15
    else:
        # Use auto-detection (default)
        test_runner = TileServerPingTest(
            server_url=base_server_url,
            webconf_root=args.webconf
        )
    
    print(f"AHTSE Tile Server Ping Test")
    print(f"Server URL: {test_runner.server_url}")
    print(f"Webconf Root: {test_runner.webconf_root}")
    print()
    
    try:
        # Run the tests
        results = test_runner.ping_all_endpoints(max_workers=args.workers)
        
        # Print summary
        if not args.quiet:
            print()  # Extra line before summary
        test_runner.print_summary(results)
        
        # Save report if requested
        if args.save_report:
            test_runner.save_detailed_report(results)
            
        # Exit with appropriate code
        failed_count = sum(1 for r in results if r['status'] in ['failed', 'error'])
        if failed_count > 0:
            sys.exit(1)
        else:
            sys.exit(0)
            
    except KeyboardInterrupt:
        print("\nTest interrupted by user.")
        sys.exit(1)
    except Exception as e:
        print(f"\nUnexpected error: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()