// Package publisher identifies this distribution's repository-owned services.
package publisher

const (
	Repository    = "study-233/free-v6"
	Branch        = "main"
	RepositoryURL = "https://github.com/" + Repository
	RawBaseURL    = "https://raw.githubusercontent.com/" + Repository + "/" + Branch
	NoticeURL     = RepositoryURL + "/raw/" + Branch + "/notice.json"
	ProfilesURL   = RawBaseURL + "/profiles/"
	// Keep caches and encrypted profiles separate from previous publishers.
	CacheNamespace = "study-233-free-v6"
)
