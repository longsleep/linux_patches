
---
 kernel/module.c |  131 +++++++++++++++++++++++++++++++++++++++++++++++---------
 1 file changed, 112 insertions(+), 19 deletions(-)

--- a/kernel/module.c
+++ b/kernel/module.c
@@ -47,7 +47,7 @@
 #include <linux/license.h>
 #include <asm/sections.h>
 
-#if 0
+#if 1
 #define DEBUGP printk
 #else
 #define DEBUGP(fmt , a...)
@@ -145,6 +145,8 @@ extern const unsigned long __start___kcr
 extern const unsigned long __start___kcrctab_gpl_future[];
 extern const unsigned long __start___kcrctab_unused[];
 extern const unsigned long __start___kcrctab_unused_gpl[];
+extern const struct module_ns __start___knamespace[];
+extern const struct module_ns __stop___knamespace[];
 
 #ifndef CONFIG_MODVERSIONS
 #define symversion(base, idx) NULL
@@ -242,11 +244,10 @@ static const struct kernel_symbol *searc
 
 /* Find a symbol, return value, (optional) crc and (optional) module
  * which owns it */
-static unsigned long find_symbol(const char *name,
-				 struct module **owner,
-				 const unsigned long **crc,
-				 bool gplok,
-				 bool warn)
+static const struct kernel_symbol *do_find_symbol(const char *name,
+						  struct module **owner,
+						  const unsigned long **crc,
+						  bool gplok, bool warn)
 {
 	struct module *mod;
 	const struct kernel_symbol *ks;
@@ -268,7 +269,7 @@ static unsigned long find_symbol(const c
 	if (ks) {
 		if (owner)
 			*owner = NULL;
-		return ks->value;
+		return ks;
 	}
 
 	/* Now try modules. */
@@ -294,12 +295,95 @@ static unsigned long find_symbol(const c
 		if (ks) {
 			if (owner)
 				*owner = mod;
-			return ks->value;
+			return ks;
 		}
 	}
 
 	DEBUGP("Failed to find symbol %s\n", name);
-	return -ENOENT;
+	return NULL;
+}
+
+/* Find namespace in a single namespace table */
+static const struct module_ns *lookup_namespace(const struct module_ns *start,
+						const struct module_ns *stop,
+						const char *name,
+						const char *reqname, int *n)
+{
+	const struct module_ns *ns;
+	for (ns = start; ns < stop; ns++)
+		if (!strcmp(name, ns->name)) {
+			(*n)++;
+			if (!strcmp(reqname, ns->allowed))
+				return ns;
+		}
+	return NULL;
+}
+
+/* Search all namespace tables for a namespace */
+static const struct module_ns *find_namespace(const char *name,
+					      const char *reqname, int *n,
+					      const struct module **modp)
+{
+	const struct module_ns *ns;
+	struct module *mod;
+	*modp = NULL;
+	ns = lookup_namespace(__start___knamespace, __stop___knamespace,
+				name, reqname, n);
+	if (ns)
+		return ns;
+	list_for_each_entry(mod, &modules, list) {
+		ns = lookup_namespace(mod->knamespace,
+				      mod->knamespace + mod->num_knamespaces,
+				      name, reqname, n);
+		if (ns) {
+			*modp = mod;
+			return ns;
+		}
+	}
+	return NULL;
+}
+
+/* Look up a symbol and check namespace */
+static unsigned long find_symbol(const char *name,
+				 struct module **owner,
+				 const unsigned long **crc,
+				 bool gplok, bool warn,
+				 struct module *requester)
+{
+	const struct kernel_symbol *ks;
+	const struct module_ns *ns;
+	const struct module *mod;
+	int n = 0;
+
+	ks = do_find_symbol(name, owner, crc, gplok, warn);
+	if (!ks)
+		return 0;
+
+	/* When the symbol has a name space check if the requesting module
+	   is white listed as allowed. */
+	if (ks->namespace) {
+		ns = find_namespace(ks->namespace, requester->name, &n, &mod);
+		if (!ns) {
+			if (n > 0)
+				printk(KERN_WARNING "module %s not allowed "
+				       "to reference namespace `%s' for %s\n",
+					requester->name, ks->namespace, name);
+			else
+				printk(KERN_WARNING "%s referencing "
+				       "undeclared namespace `%s' for %s\n",
+					requester->name, ks->namespace, name);
+			return 0;
+		}
+		/* Only allow name space declarations in the symbol's own
+		   module. */
+		if (mod != *owner) {
+			printk(KERN_WARNING "namespace `%s' for symbol `%s' "
+			       "defined in wrong module `%s'\n",
+				name, name, mod->name);
+			return 0;
+		}
+	}
+	return ks->value;
 }
 
 /* Search for module by name: must hold module_mutex. */
@@ -784,17 +868,17 @@ static void print_unload_info(struct seq
 		seq_printf(m, "-");
 }
 
-void __symbol_put(const char *symbol)
+void do_symbol_put(const char *symbol, struct module *caller)
 {
 	struct module *owner;
 
 	preempt_disable();
-	if (IS_ERR_VALUE(find_symbol(symbol, &owner, NULL, true, false)))
+	if (!find_symbol(symbol, &owner, NULL, true, false, caller))
 		BUG();
 	module_put(owner);
 	preempt_enable();
 }
-EXPORT_SYMBOL(__symbol_put);
+EXPORT_SYMBOL(do_symbol_put);
 
 void symbol_put_addr(void *addr)
 {
@@ -952,7 +1036,8 @@ static inline int check_modstruct_versio
 {
 	const unsigned long *crc;
 
-	if (IS_ERR_VALUE(find_symbol("struct_module", NULL, &crc, true, false)))
+	if (IS_ERR_VALUE(find_symbol("struct_module", NULL, &crc,
+				     true, false, mod)))
 		BUG();
 	return check_version(sechdrs, versindex, "struct_module", mod, crc);
 }
@@ -1003,7 +1088,7 @@ static unsigned long resolve_symbol(Elf_
 	const unsigned long *crc;
 
 	ret = find_symbol(name, &owner, &crc,
-			  !(mod->taints & TAINT_PROPRIETARY_MODULE), true);
+			  !(mod->taints & TAINT_PROPRIETARY_MODULE), true, mod);
 	if (!IS_ERR_VALUE(ret)) {
 		/* use_module can fail due to OOM,
 		   or module initialization or unloading */
@@ -1412,13 +1497,13 @@ static void free_module(struct module *m
 	module_free(mod, mod->module_core);
 }
 
-void *__symbol_get(const char *symbol)
+void *do_symbol_get(const char *symbol, struct module *caller)
 {
 	struct module *owner;
 	unsigned long value;
 
 	preempt_disable();
-	value = find_symbol(symbol, &owner, NULL, true, true);
+	value = find_symbol(symbol, &owner, NULL, true, true, caller);
 	if (IS_ERR_VALUE(value))
 		value = 0;
 	else if (strong_try_module_get(owner))
@@ -1427,7 +1512,7 @@ void *__symbol_get(const char *symbol)
 
 	return (void *)value;
 }
-EXPORT_SYMBOL_GPL(__symbol_get);
+EXPORT_SYMBOL_GPL(do_symbol_get);
 
 /*
  * Ensure that an exported symbol [global namespace] does not already exist
@@ -1451,8 +1536,8 @@ static int verify_export_symbols(struct 
 
 	for (i = 0; i < ARRAY_SIZE(arr); i++) {
 		for (s = arr[i].sym; s < arr[i].sym + arr[i].num; s++) {
-			if (!IS_ERR_VALUE(find_symbol(s->name, &owner,
-						      NULL, true, false))) {
+			if (!IS_ERR_VALUE(find_symbol(s->name, &owner, NULL,
+						      true, false, mod))) {
 				printk(KERN_ERR
 				       "%s: exports duplicate symbol %s"
 				       " (owned by %s)\n",
@@ -1770,6 +1855,7 @@ static struct module *load_module(void _
 	unsigned int unusedgplcrcindex;
 	unsigned int markersindex;
 	unsigned int markersstringsindex;
+	unsigned int namespaceindex;
 	struct module *mod;
 	long err = 0;
 	void *percpu = NULL, *ptr = NULL; /* Stops spurious gcc warning */
@@ -1866,6 +1952,7 @@ static struct module *load_module(void _
 #ifdef ARCH_UNWIND_SECTION_NAME
 	unwindex = find_sec(hdr, sechdrs, secstrings, ARCH_UNWIND_SECTION_NAME);
 #endif
+	namespaceindex = find_sec(hdr, sechdrs, secstrings, "__knamespace");
 
 	/* Don't keep modinfo and version sections. */
 	sechdrs[infoindex].sh_flags &= ~(unsigned long)SHF_ALLOC;
@@ -2034,6 +2121,12 @@ static struct module *load_module(void _
 		mod->unused_gpl_crcs
 			= (void *)sechdrs[unusedgplcrcindex].sh_addr;
 
+	if (namespaceindex) {
+		mod->knamespace = (void *)sechdrs[namespaceindex].sh_addr;
+		mod->num_knamespaces = sechdrs[namespaceindex].sh_size /
+					sizeof(*mod->knamespace);
+	}
+
 #ifdef CONFIG_MODVERSIONS
 	if ((mod->num_syms && !crcindex) ||
 	    (mod->num_gpl_syms && !gplcrcindex) ||
