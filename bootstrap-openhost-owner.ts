import 'dotenv/config';

import {
  and,
  db,
  eq,
  organization,
  organizationmember,
  organizationPlan,
  profile,
  user
} from '@db/drizzle';
import { ROLE } from '@cio/utils/constants';
import { PLAN } from '@cio/utils/plans';

const [orgName, ownerEmailArg, siteName] = process.argv.slice(2);
const ownerEmail = ownerEmailArg?.trim().toLowerCase();

if (!orgName || !ownerEmail || !siteName) {
  throw new Error('Usage: openhost-owner.ts <organization-name> <owner-email> <site-name>');
}

async function ensureOwnerUser(): Promise<string> {
  const [existingUser] = await db.select({ id: user.id }).from(user).where(eq(user.email, ownerEmail)).limit(1);
  let userId = existingUser?.id;

  if (!userId) {
    const [createdUser] = await db
      .insert(user)
      .values({ name: 'Owner', email: ownerEmail, emailVerified: true })
      .returning({ id: user.id });
    userId = createdUser.id;
  }

  const [existingProfile] = await db.select({ id: profile.id }).from(profile).where(eq(profile.id, userId)).limit(1);
  if (!existingProfile) {
    await db.insert(profile).values({
      id: userId,
      username: `openhost-owner-${userId.slice(0, 8)}`,
      fullname: 'Owner',
      email: ownerEmail,
      canAddCourse: true,
      isEmailVerified: true
    });
  }

  return userId;
}

async function ensureOwnerOrganization(userId: string): Promise<void> {
  await db.transaction(async (tx) => {
    let [org] = await tx.select().from(organization).limit(1);
    if (!org) {
      [org] = await tx.insert(organization).values({ name: orgName, siteName }).returning();
    }

    const [existingMember] = await tx
      .select()
      .from(organizationmember)
      .where(and(eq(organizationmember.organizationId, org.id), eq(organizationmember.profileId, userId)))
      .limit(1);

    let member = existingMember;
    if (!member) {
      [member] = await tx
        .insert(organizationmember)
        .values({ organizationId: org.id, profileId: userId, roleId: ROLE.ADMIN, verified: true })
        .returning();
    } else if (member.roleId !== ROLE.ADMIN || !member.verified) {
      [member] = await tx
        .update(organizationmember)
        .set({ roleId: ROLE.ADMIN, verified: true })
        .where(eq(organizationmember.id, member.id))
        .returning();
    }

    const [activePlan] = await tx
      .select({ id: organizationPlan.id })
      .from(organizationPlan)
      .where(and(eq(organizationPlan.orgId, org.id), eq(organizationPlan.isActive, true)))
      .limit(1);
    if (!activePlan) {
      await tx.insert(organizationPlan).values({
        orgId: org.id,
        planName: PLAN.ENTERPRISE,
        subscriptionId: `openhost-${org.id}`,
        triggeredBy: member.id,
        provider: 'openhost',
        payload: {},
        isActive: true
      });
    }
  });
}

async function main(): Promise<void> {
  const userId = await ensureOwnerUser();
  await ensureOwnerOrganization(userId);
  console.log(`OpenHost owner ready: ${ownerEmail} (${userId})`);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error('OpenHost owner bootstrap failed:', error);
    process.exit(1);
  });
