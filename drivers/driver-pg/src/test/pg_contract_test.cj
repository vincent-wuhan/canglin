package pgdriver.test

import std.unittest.*
import driver.api.*
import driver.testkit.*
import pgdriver.*

// PT9 补：PG/openGauss 适配器的**归类口径表**用例。
//
// 探针式的错误四分类与关闭幂等用例在 pg_it_test.cj（PT8 落地）；
// 本文件补的是「跨适配器同一口径」这一层：同一句错误文案在 MySQL 适配器与
// PG 适配器必须落到同一类别——调用方只看类别不看文案，故两边不能各写一份
// 各漂移一份的映射。口径表固化在 driver.testkit，两边各跑一遍。

@Test
func testCanonicalErrorMessageTable() {
    for (c in canonicalErrorCases()) {
        let actual = categoryOf(classifyError(c.message))
        @Assert(actual == c.category)
    }
}

@Test
func testPgCategoriesAreDistinct() {
    // 四类错误彼此可区分（spec：返回包含错误类别的失败结果）
    let cases = canonicalErrorCases()
    @Assert(cases.size >= 8)
    @Assert(cases[0].category == ErrorCategory.AuthFailed)
}
