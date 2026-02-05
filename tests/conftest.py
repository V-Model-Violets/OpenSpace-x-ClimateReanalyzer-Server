#!/usr/bin/env python3
"""
pytest configuration and fixtures for AHTSE tile server testing.
"""

import pytest
import os
import sys

# Add current directory to path to import utils
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from utils import WebconfParser, TileEndpointGenerator, get_server_url, get_webconf_root


@pytest.fixture(scope="session")
def server_url():
    """Fixture providing the base server URL."""
    return get_server_url()


@pytest.fixture(scope="session") 
def webconf_parser():
    """Fixture providing a configured WebconfParser instance."""
    return WebconfParser(get_webconf_root())


@pytest.fixture(scope="session")
def tile_generator(server_url):
    """Fixture providing a configured TileEndpointGenerator instance."""
    return TileEndpointGenerator(server_url)


@pytest.fixture(scope="session")
def discovered_endpoints(webconf_parser):
    """Fixture providing all discovered endpoints."""
    return webconf_parser.discover_all_endpoints()


@pytest.fixture
def sample_tile_coordinates():
    """Fixture providing sample tile coordinates for testing."""
    return [
        (0, 0, 0),  # Zoom 0, tile 0,0
        (1, 0, 0),  # Zoom 1, tile 0,0
        (2, 1, 1),  # Zoom 2, tile 1,1
    ]