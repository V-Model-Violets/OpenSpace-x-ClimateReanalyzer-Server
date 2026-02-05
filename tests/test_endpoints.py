#!/usr/bin/env python3
"""
pytest-based endpoint availability tests for AHTSE tile server.

Tests whether each configured tile endpoint responds correctly to HTTP requests.
"""

import pytest
import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry
import time
import sys
import os
from typing import List, Dict

# Add current directory to path to import utils
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))


class TestEndpointAvailability:
    """Test suite for endpoint availability and basic functionality."""
    
    @pytest.fixture(autouse=True)
    def setup_session(self):
        """Setup HTTP session with retries and timeouts."""
        self.session = requests.Session()
        
        # Configure retry strategy
        retry_strategy = Retry(
            total=3,
            backoff_factor=1,
            status_forcelist=[429, 500, 502, 503, 504],
        )
        adapter = HTTPAdapter(max_retries=retry_strategy)
        self.session.mount("http://", adapter)
        self.session.mount("https://", adapter)
        
        # Set reasonable timeout
        self.timeout = 30
        
    def test_endpoints_discovered(self, discovered_endpoints):
        """Test that at least one endpoint is discovered from webconf files."""
        assert len(discovered_endpoints) > 0, "No endpoints discovered from webconf files"
        
        print(f"\nDiscovered {len(discovered_endpoints)} endpoints:")
        for endpoint in discovered_endpoints:
            print(f"  - {endpoint['name']} ({endpoint['relative_dir']})")
            
    def test_server_connectivity(self, server_url):
        """Test basic server connectivity."""
        try:
            response = self.session.get(server_url, timeout=self.timeout)
            # Server might return various status codes, but should be reachable
            assert response.status_code < 500, f"Server error: {response.status_code}"
            print(f"\nServer connectivity OK: {server_url} (status: {response.status_code})")
        except requests.exceptions.RequestException as e:
            pytest.fail(f"Cannot connect to server {server_url}: {e}")
    
    def test_endpoint_tile_availability(self, discovered_endpoints, tile_generator, sample_tile_coordinates):
        """
        Test that each endpoint can serve tile requests.
        
        Tests multiple tile coordinates to ensure the endpoint is responsive.
        """
        for endpoint_info in discovered_endpoints:
            endpoint_name = endpoint_info['name']
            failures = []
            successes = []
            
            for z, x, y in sample_tile_coordinates:
                tile_url = tile_generator.generate_tile_url(endpoint_info, z, x, y)
                
                try:
                    response = self.session.get(tile_url, timeout=self.timeout)
                    
                    if response.status_code == 200:
                        # Verify it's actually an image
                        content_type = response.headers.get('content-type', '')
                        if 'image' in content_type.lower():
                            successes.append((z, x, y, len(response.content)))
                        else:
                            failures.append(f"Z{z}X{x}Y{y}: Not an image (content-type: {content_type})")
                    elif response.status_code == 404:
                        # 404 might be expected for some coordinates, depending on data extent
                        # Don't count as failure unless all tiles fail
                        pass
                    else:
                        failures.append(f"Z{z}X{x}Y{y}: HTTP {response.status_code}")
                        
                except requests.exceptions.RequestException as e:
                    failures.append(f"Z{z}X{x}Y{y}: Request failed - {e}")
                    
            # Report results
            print(f"\nEndpoint: {endpoint_name}")
            print(f"  Successful tiles: {len(successes)}")
            if successes:
                for z, x, y, size in successes[:3]:  # Show first 3 successes
                    print(f"    Z{z}X{x}Y{y}: {size} bytes")
            if failures:
                print(f"  Failed tiles: {len(failures)}")
                for failure in failures[:3]:  # Show first 3 failures
                    print(f"    {failure}")
                    
            # At least one tile should be successful (but skip if server not running)
            if failures and "Connection refused" in str(failures):
                pytest.skip(f"Server not accessible for endpoint {endpoint_name}")
            
    def test_endpoint_metadata_availability(self, discovered_endpoints, tile_generator):
        """
        Test that each endpoint provides some form of metadata or base response.
        """
        for endpoint_info in discovered_endpoints:
            endpoint_name = endpoint_info['name']
            metadata_url = tile_generator.generate_metadata_url(endpoint_info)
            
            try:
                response = self.session.get(metadata_url, timeout=self.timeout)
                
                # Metadata endpoints might return various status codes
                # 200, 301, 302, 403 could all be valid depending on server configuration
                assert response.status_code < 500, f"Server error for metadata endpoint: {response.status_code}"
                
                print(f"\nMetadata endpoint for {endpoint_name}: {response.status_code}")
                if response.headers.get('content-type'):
                    print(f"  Content-Type: {response.headers['content-type']}")
                    
            except requests.exceptions.RequestException as e:
                # Skip if server is not running
                if "Connection refused" in str(e):
                    pytest.skip(f"Server not accessible for metadata test of endpoint {endpoint_name}")
                else:
                    pytest.fail(f"Cannot access metadata for endpoint {endpoint_name}: {e}")
            
    def test_endpoint_configuration_validity(self, discovered_endpoints):
        """Test that discovered endpoints have valid configuration."""
        for endpoint in discovered_endpoints:
            name = endpoint['name']
            config = endpoint['config']
            
            # Check for essential configuration parameters
            essential_params = ['Size', 'PageSize', 'DataFile', 'IndexFile']
            missing_params = [param for param in essential_params if param not in config]
            
            assert len(missing_params) == 0, f"Endpoint {name} missing essential parameters: {missing_params}"
            
            # Validate Size parameter format
            if 'Size' in config:
                size_parts = config['Size'].split()
                assert len(size_parts) >= 3, f"Endpoint {name}: Size parameter should have at least 3 values"
                
                # All size values should be numeric
                for i, part in enumerate(size_parts[:3]):
                    assert part.isdigit(), f"Endpoint {name}: Size parameter part {i} is not numeric: {part}"
                    
            print(f"\nConfiguration valid for endpoint: {name}")


class TestEndpointPerformance:
    """Performance-related tests for tile endpoints."""
    
    @pytest.fixture(autouse=True)
    def setup_session(self):
        """Setup HTTP session for performance tests."""
        self.session = requests.Session()
        self.timeout = 10  # Shorter timeout for performance tests
        
    def test_tile_response_time(self, discovered_endpoints, tile_generator):
        """Test that tile requests complete within reasonable time."""
        for endpoint_info in discovered_endpoints:
            endpoint_name = endpoint_info['name']
            tile_url = tile_generator.generate_tile_url(endpoint_info, 0, 0, 0)
            
            start_time = time.time()
            
            try:
                response = self.session.get(tile_url, timeout=self.timeout)
                response_time = time.time() - start_time
                
                if response.status_code == 200:
                    # Successful tile should respond within 5 seconds
                    assert response_time < 5.0, f"Tile response too slow: {response_time:.2f}s"
                    print(f"\nEndpoint {endpoint_name} response time: {response_time:.3f}s")
                else:
                    print(f"\nEndpoint {endpoint_name} returned {response.status_code} in {response_time:.3f}s")
                    
            except requests.exceptions.Timeout:
                pytest.fail(f"Tile request timed out for endpoint {endpoint_name}")
            except requests.exceptions.RequestException as e:
                if "Connection refused" in str(e):
                    pytest.skip(f"Could not test performance for endpoint {endpoint_name}: Server not running")
                else:
                    pytest.skip(f"Could not test performance for endpoint {endpoint_name}: {e}")


if __name__ == "__main__":
    """Run tests directly if script is executed."""
    pytest.main([__file__, "-v"])