package main

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"sync"
)

// DirEntry represents a file or directory entry with its metadata
type DirEntry struct {
	Path  string
	MTime int64
	IsDir bool
}

// DirHashOptions defines options for directory hashing
type DirHashOptions struct {
	BatchSize int // Number of files to process in a batch
	Workers   int // Number of worker goroutines
}

// DefaultDirHashOptions provides reasonable default settings
var DefaultDirHashOptions = DirHashOptions{
	BatchSize: 100,
	Workers:   40,
}

// CalculateDirHash calculates a hash for a directory based on file paths and mtimes
func CalculateDirHash(dirPath string, options DirHashOptions) (string, error) {
	// Use default options if invalid values are provided
	if options.BatchSize <= 0 {
		options.BatchSize = DefaultDirHashOptions.BatchSize
	}
	if options.Workers <= 0 {
		options.Workers = DefaultDirHashOptions.Workers
	}

	// Channel to receive file paths
	pathChan := make(chan string, options.BatchSize)

	// Channel to receive processed entries
	entryChan := make(chan DirEntry, options.BatchSize)

	// Channel for errors
	errChan := make(chan error, 1)

	// WaitGroup for worker goroutines
	var wg sync.WaitGroup

	// Start worker goroutines to process files
	for i := 0; i < options.Workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()

			for path := range pathChan {
				info, err := os.Stat(path)
				if err != nil {
					select {
					case errChan <- fmt.Errorf("error stating file %s: %w", path, err):
					default:
						// If error channel is full, continue
					}
					continue
				}

				relPath, err := filepath.Rel(dirPath, path)
				if err != nil {
					select {
					case errChan <- fmt.Errorf("error getting relative path for %s: %w", path, err):
					default:
						// If error channel is full, continue
					}
					continue
				}

				entry := DirEntry{
					Path:  relPath,
					MTime: info.ModTime().UnixNano(),
					IsDir: info.IsDir(),
				}

				entryChan <- entry
			}
		}()
	}

	// Start a goroutine to walk the directory
	go func() {
		defer close(pathChan)

		err := filepath.Walk(dirPath, func(path string, info os.FileInfo, err error) error {
			if err != nil {
				return err
			}
			if path == dirPath {
				return nil // Skip the root directory itself
			}

			pathChan <- path
			return nil
		})

		if err != nil {
			select {
			case errChan <- fmt.Errorf("error walking directory: %w", err):
			default:
				// If error channel is full, continue
			}
		}
	}()

	// Start a goroutine to wait for all workers to finish and then close the entry channel
	go func() {
		wg.Wait()
		close(entryChan)
	}()

	// Collect all entries
	var dirEntries []DirEntry
	for entry := range entryChan {
		dirEntries = append(dirEntries, entry)
	}

	// Check if there were any errors
	select {
	case err := <-errChan:
		return "", err
	default:
		// No errors, continue
	}

	// Sort entries by path for consistent hashing
	sort.Slice(dirEntries, func(i, j int) bool {
		return dirEntries[i].Path < dirEntries[j].Path
	})

	// Calculate hash
	hasher := sha256.New()
	for _, entry := range dirEntries {
		// Format: path:mtime:isDir
		data := fmt.Sprintf("%s:%d:%t", entry.Path, entry.MTime, entry.IsDir)
		hasher.Write([]byte(data))
	}

	hash := hex.EncodeToString(hasher.Sum(nil))
	return hash, nil
}

func main() {
	// Example usage
	dirPath := "/Users/vadymh/work/odeditor-packages2/node_modules/.store-fuse-unplugged"

	dirs, _ := os.ReadDir(dirPath)
	for _, dir := range dirs {
		p := filepath.Join(dirPath, dir.Name(), "package")
		hash, err := CalculateDirHash(p, DefaultDirHashOptions)
		if err != nil {
			fmt.Printf("Error calculating directory hash: %v\n", err)
			// return
		}
		fmt.Printf("Directory hash for %s: %s\n", p, hash)
	}

}
