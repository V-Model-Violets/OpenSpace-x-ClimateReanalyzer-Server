#!/usr/bin/env python3
"""
Utility functions for AHTSE tile server testing.
Handles parsing of webconf files and discovery of available endpoints.
"""

import os
import re
import glob
from typing import List, Dict, Tuple, Optional
from urllib.parse import urljoin


class WebconfParser:
    """Parser for AHTSE webconf files to extract tile server configuration."""
    
    def __init__(self, webconf_root: str = None):
        """Initialize parser with webconf root directory."""
        if webconf_root is None:
            # Default to webconf directory relative to this script
            script_dir = os.path.dirname(os.path.abspath(__file__))
            webconf_root = os.path.join(os.path.dirname(script_dir), 'webconf')
        
        self.webconf_root = webconf_root
        
    def parse_webconf_file(self, webconf_path: str) -> Dict[str, str]:
        """
        Parse a single .webconf file to extract configuration.
        
        Args:
            webconf_path: Path to the .webconf file
            
        Returns:
            Dictionary containing configuration parameters
        """
        config = {}
        
        try:
            with open(webconf_path, 'r') as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith('#'):
                        continue
                    
                    # Parse key-value pairs
                    parts = line.split(None, 1)  # Split on whitespace, max 2 parts
                    if len(parts) >= 2:
                        key = parts[0]
                        value = parts[1]
                        config[key] = value
                    elif len(parts) == 1:
                        # Handle single word directives
                        config[parts[0]] = True
                        
        except (IOError, OSError) as e:
            print(f"Warning: Could not read {webconf_path}: {e}")
            
        return config
        
    def discover_webconf_files(self) -> List[str]:
        """
        Discover all .webconf files in the webconf directory tree.
        
        Returns:
            List of absolute paths to .webconf files
        """
        webconf_files = []
        
        if not os.path.exists(self.webconf_root):
            print(f"Warning: webconf root directory not found: {self.webconf_root}")
            return webconf_files
            
        for root, dirs, files in os.walk(self.webconf_root):
            for file in files:
                if file.endswith('.webconf'):
                    webconf_files.append(os.path.join(root, file))
                    
        return sorted(webconf_files)
        
    def get_endpoint_info(self, webconf_path: str) -> Dict[str, str]:
        """
        Extract endpoint information from a webconf file.
        
        Args:
            webconf_path: Path to the .webconf file
            
        Returns:
            Dictionary with endpoint information including name, relative path, etc.
        """
        config = self.parse_webconf_file(webconf_path)
        
        # Get relative path from webconf root
        rel_path = os.path.relpath(webconf_path, self.webconf_root)
        rel_dir = os.path.dirname(rel_path)
        
        # Extract name from filename
        filename = os.path.basename(webconf_path)
        name = os.path.splitext(filename)[0]
        
        endpoint_info = {
            'name': name,
            'webconf_path': webconf_path,
            'relative_dir': rel_dir,
            'config': config
        }
        
        # Extract size information if available
        if 'Size' in config:
            size_parts = config['Size'].split()
            if len(size_parts) >= 3:
                endpoint_info['width'] = int(size_parts[0])
                endpoint_info['height'] = int(size_parts[1])
                endpoint_info['bands'] = int(size_parts[2])
                if len(size_parts) >= 4:
                    endpoint_info['levels'] = int(size_parts[3])
                    
        return endpoint_info
        
    def discover_all_endpoints(self) -> List[Dict[str, str]]:
        """
        Discover all configured endpoints.
        
        Returns:
            List of endpoint information dictionaries
        """
        endpoints = []
        webconf_files = self.discover_webconf_files()
        
        for webconf_path in webconf_files:
            endpoint_info = self.get_endpoint_info(webconf_path)
            endpoints.append(endpoint_info)
            
        return endpoints


class TileEndpointGenerator:
    """Generate tile URLs for testing AHTSE endpoints."""
    
    def __init__(self, base_url: str = "http://localhost"):
        """Initialize with base server URL."""
        self.base_url = base_url.rstrip('/')
        
    def generate_tile_url(self, endpoint_info: Dict[str, str], 
                         z: int = 0, x: int = 0, y: int = 0) -> str:
        """
        Generate a tile URL for the given endpoint and coordinates.
        
        Args:
            endpoint_info: Endpoint information from WebconfParser
            z: Zoom level (default: 0)
            x: Tile x coordinate (default: 0)  
            y: Tile y coordinate (default: 0)
            
        Returns:
            Complete tile URL
        """
        # AHTSE URL format: /tiles/{relative_dir}/tile/{z}/{x}/{y}
        # Example: /tiles/Tif/Gebco/tile/0/0/0
        rel_dir = endpoint_info.get('relative_dir', '')
        name = endpoint_info.get('name', 'unknown')
        
        # Use relative_dir directly as it already includes the dataset name
        if rel_dir:
            tile_path = f"/tiles/{rel_dir}/tile/{z}/{x}/{y}"
        else:
            tile_path = f"/tiles/{name}/tile/{z}/{x}/{y}"
            
        # Generate complete tile URL
        tile_url = f"{self.base_url}{tile_path}"
        
        return tile_url
        
    def generate_test_urls(self, endpoint_info: Dict[str, str], 
                          num_levels: int = 2, tiles_per_level: int = 2) -> List[str]:
        """
        Generate multiple tile URLs for comprehensive testing.
        
        Args:
            endpoint_info: Endpoint information
            num_levels: Number of zoom levels to test
            tiles_per_level: Number of tiles to test per level
            
        Returns:
            List of tile URLs for testing
        """
        urls = []
        
        max_levels = endpoint_info.get('levels', 7)  # Default from typical webconf
        test_levels = min(num_levels, max_levels)
        
        for z in range(test_levels):
            for x in range(tiles_per_level):
                for y in range(tiles_per_level):
                    url = self.generate_tile_url(endpoint_info, z, x, y)
                    urls.append(url)
                    
        return urls
        
    def generate_metadata_url(self, endpoint_info: Dict[str, str]) -> str:
        """
        Generate URL for metadata/capabilities endpoint.
        
        Args:
            endpoint_info: Endpoint information
            
        Returns:
            Metadata URL
        """
        rel_dir = endpoint_info.get('relative_dir', '')
        name = endpoint_info.get('name', 'unknown')
        
        # Construct the metadata URL with /tiles/ prefix
        # Format: /tiles/{relative_dir}/
        if rel_dir:
            metadata_path = f"/tiles/{rel_dir}/"
        else:
            metadata_path = f"/tiles/{name}/"
            
        metadata_url = f"{self.base_url}{metadata_path}"
        
        return metadata_url


def get_server_url() -> str:
    """
    Get the server URL from environment or use default.
    
    Supports GitHub Actions and CI environments by checking multiple env vars.
    Also handles common redirect scenarios.
    
    Returns:
        Server base URL
    """
    # Check for GitHub Actions or CI-specific environment variables
    if os.environ.get('GITHUB_ACTIONS'):
        # Default GitHub Actions setup
        port = os.environ.get('TILE_SERVER_PORT', '62134')
        return f"http://localhost:{port}"
    
    # Check for explicit server URL (most flexible)
    if 'TILE_SERVER_URL' in os.environ:
        return os.environ['TILE_SERVER_URL']
    
    # Check for port-only specification
    if 'TILE_SERVER_PORT' in os.environ:
        port = os.environ['TILE_SERVER_PORT']
        return f"http://localhost:{port}"
    
    # Default fallback
    return 'http://localhost'


def detect_server_url(base_url: str = None) -> str:
    """
    Detect the actual server URL by testing common ports and following redirects.
    
    Args:
        base_url: Base URL to start detection from
        
    Returns:
        Detected server URL that actually responds
    """
    if base_url is None:
        base_url = get_server_url()
        
    # Common ports to try
    common_ports = [62134, 62135, 8080, 80, 3000]
    
    # Extract base host from URL
    from urllib.parse import urlparse
    parsed = urlparse(base_url)
    host = parsed.hostname or 'localhost'
    scheme = parsed.scheme or 'http'
    
    # If a specific port was provided, try it first
    ports_to_try = []
    if parsed.port:
        ports_to_try.append(parsed.port)
    
    # Add common ports
    for port in common_ports:
        if port not in ports_to_try:
            ports_to_try.append(port)
            
    import requests
    
    for port in ports_to_try:
        test_url = f"{scheme}://{host}:{port}"
        try:
            # Test with a simple request that allows redirects
            response = requests.get(test_url, timeout=5, allow_redirects=True)
            if response.status_code < 500:  # Server responding
                # Check if we were redirected to a different URL
                final_url = response.url
                if final_url and final_url != test_url:
                    final_parsed = urlparse(final_url)
                    return f"{final_parsed.scheme}://{final_parsed.netloc}"
                return test_url
        except requests.exceptions.RequestException:
            continue
            
    # If no server found, return the original URL
    return base_url


def get_webconf_root() -> str:
    """
    Get the webconf root directory path.
    
    Returns:
        Absolute path to webconf directory
    """
    script_dir = os.path.dirname(os.path.abspath(__file__))
    return os.path.join(os.path.dirname(script_dir), 'webconf')