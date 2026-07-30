/// The shared UUID generator.
///
/// Every id-minting site used to reach this through
/// `package:powersync/powersync.dart show uuid`, which re-exported a ready-made
/// `Uuid` instance. The engine is gone and `uuid` is a direct dependency, so the
/// instance lives here instead — one const object rather than a `const Uuid()`
/// repeated at a dozen call sites, and one place to look when the id scheme is
/// in question.
///
/// v4 for owned entities the client declares (`clientDefault` on the table), v5
/// over `Namespace.url` for derived ids two devices have to agree on without
/// talking — see `sync/ids.dart` and the `*IdFor` helpers in the DAOs.
library;

import 'package:uuid/uuid.dart';

const Uuid uuid = Uuid();
