# OpenSpace-x-ClimateReanalyzer

## How to develop in OpenSpace-x-ClimateReanalyzer

### Clone the Repository
To clone the repo, open a terminal window (in a directory of your choice) and run `git clone git@github.com:V-Model-Violets/OpenSpace-x-ClimateReanalyzer.git`

### Opening the Repository
Navigate to the project folder (for example: `cd ~/repos/OpenSpace-x-ClimateReanalyzer`) and run `code .`

### Dev Containers
When prompted, select "Reopen in Container" 

<img width="448" height="123" alt="Screenshot 2025-10-15 at 4 09 07 PM" src="https://github.com/user-attachments/assets/532ac0c1-5575-44b1-8102-d32cf334e022" />


If you don't get this message, press `Command/Control + Shift + P`, then press `Dev Containers: Reopen in Container`
## Testing

This project includes comprehensive unit tests to verify that all tile server endpoints are accessible and functioning correctly.

### Quick Test Run

To quickly check if all tile endpoints are accessible:

```bash
# Install test dependencies
pip install -r tests/requirements.txt

# Run the standalone ping test
python tests/ping_test.py
```

### Full Test Suite

For comprehensive testing with detailed reports:

```bash
# Run all tests with pytest
python -m pytest tests/ -v

# Generate HTML test report
python -m pytest tests/ --html=tests/report.html --self-contained-html
```

### Test Configuration

By default, tests assume the tile server is running on `http://localhost`. You can customize this for different environments:

```bash
# Test against different server and port (e.g., for GitHub Actions)
export TILE_SERVER_PORT=62134
python tests/ping_test.py

# Or specify complete URL
export TILE_SERVER_URL=http://localhost:8080
python tests/ping_test.py

# Or pass directly as argument
python tests/ping_test.py --server http://your-server.com:62134
```

### Understanding Test Results

The tests verify:
- **Endpoint Discovery**: All `.webconf` files are properly parsed
- **Server Connectivity**: Basic server accessibility  
- **Tile Availability**: Sample tiles can be retrieved using z/x/y format (e.g., `/tiles/Tif/Gebco/tile/0/0/0`)
- **Response Performance**: Tiles load within reasonable time limits
- **Configuration Validity**: Endpoint configurations are complete and valid

See [tests/README.md](tests/README.md) for detailed testing information.

