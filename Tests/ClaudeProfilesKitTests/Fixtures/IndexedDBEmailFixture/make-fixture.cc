// Builds Fixtures/IndexedDBEmailFixture: a LevelDB database like Chromium's IndexedDB for claude.ai, whose only
// table is Snappy-compressed, so the account's profile record can't be found by scanning the file's bytes.
#include <leveldb/db.h>
#include <leveldb/comparator.h>
#include <leveldb/options.h>
#include <cstdio>
#include <string>

struct IdbComparator : leveldb::Comparator {
  int Compare(const leveldb::Slice& a, const leveldb::Slice& b) const override { return a.compare(b); }
  const char* Name() const override { return "idb_cmp1"; }
  void FindShortestSeparator(std::string*, const leveldb::Slice&) const override {}
  void FindShortSuccessor(std::string*) const override {}
};

static std::string str(const std::string& s) { return std::string("\x22", 1) + char(s.size()) + s; }

int main(int argc, char** argv) {
  const std::string account = "cccccccc-dddd-4eee-8fff-000000000001";
  IdbComparator cmp;
  leveldb::Options options;
  options.create_if_missing = true;
  options.comparator = &cmp;
  options.compression = leveldb::kSnappyCompression;
  leveldb::DB* db;
  if (!leveldb::DB::Open(options, argv[1], &db).ok()) return 1;
  std::string pad(160, '-');
  // The account id, far from any email_address; then email_address, far from any account id.
  db->Put({}, "a-account", "\xff\x0f" + str("lastKnownAccountUuid") + str(account) + str(pad));
  db->Put({}, "b-other", "\xff\x0f" + str(pad) + str("email_address") + str("someone@other.example") + str(pad));
  // The profile: its account id and email_address repeat the ones above, so Snappy stores them as back-references.
  db->Put({}, "c-profile", "\xff\x0f\x6f" + str("uuid") + str(account) + str("email_address") + str("me@snappy.example") + "\x7b\x02");
  db->CompactRange(nullptr, nullptr);
  delete db;
  return 0;
}
