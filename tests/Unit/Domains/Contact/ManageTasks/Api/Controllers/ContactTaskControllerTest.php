<?php

namespace Tests\Unit\Domains\Contact\ManageTasks\Api\Controllers;

use App\Models\Contact;
use App\Models\ContactTask;
use App\Models\Vault;
use Illuminate\Foundation\Testing\DatabaseTransactions;
use Tests\ApiTestCase;

class ContactTaskControllerTest extends ApiTestCase
{
    use DatabaseTransactions;

    /** @test */
    public function it_gets_a_list_of_tasks_in_a_vault(): void
    {
        $user = $this->createUser(['read']);

        $vault = Vault::factory()->create([
            'account_id' => $user->account_id,
        ]);
        $contact = Contact::factory()->create([
            'vault_id' => $vault->id,
        ]);
        $task = ContactTask::factory()->create([
            'contact_id' => $contact->id,
            'label' => 'Buy flowers for his birthday',
        ]);

        // a task in another vault must not appear
        ContactTask::factory()->create();

        $response = $this->get('/api/vaults/'.$vault->id.'/tasks');

        $response->assertStatus(200);
        $response->assertJsonCount(1, 'data');
        $response->assertJsonPath('data.0.id', $task->id);
        $response->assertJsonPath('data.0.label', 'Buy flowers for his birthday');
        $response->assertJsonPath('data.0.completed', false);
        $response->assertJsonPath('data.0.contact.id', $contact->id);
    }

    /** @test */
    public function it_toggles_a_task(): void
    {
        $user = $this->createUser(['read', 'write']);

        $vault = Vault::factory()->create([
            'account_id' => $user->account_id,
        ]);
        $vault = $this->setPermissionInVault($user, Vault::PERMISSION_EDIT, $vault);

        $contact = Contact::factory()->create([
            'vault_id' => $vault->id,
        ]);
        $task = ContactTask::factory()->create([
            'contact_id' => $contact->id,
            'completed' => false,
        ]);

        $response = $this->put('/api/vaults/'.$vault->id.'/tasks/'.$task->id.'/toggle');

        $response->assertStatus(200);
        $response->assertJsonPath('data.id', $task->id);
        $response->assertJsonPath('data.completed', true);

        $this->assertDatabaseHas('contact_tasks', [
            'id' => $task->id,
            'completed' => true,
        ]);
    }

    /** @test */
    public function it_creates_a_task(): void
    {
        $user = $this->createUser(['read', 'write']);

        $vault = Vault::factory()->create([
            'account_id' => $user->account_id,
        ]);
        $vault = $this->setPermissionInVault($user, Vault::PERMISSION_EDIT, $vault);

        $contact = Contact::factory()->create([
            'vault_id' => $vault->id,
        ]);

        $response = $this->post('/api/vaults/'.$vault->id.'/contacts/'.$contact->id.'/tasks', [
            'label' => 'Call him back',
            'description' => 'About the deal',
        ]);

        $response->assertStatus(201);
        $response->assertJsonPath('data.label', 'Call him back');
        $response->assertJsonPath('data.contact.id', $contact->id);

        $this->assertDatabaseHas('contact_tasks', [
            'contact_id' => $contact->id,
            'label' => 'Call him back',
        ]);
    }

    /** @test */
    public function it_gets_an_exception_toggling_a_task_in_another_account_vault(): void
    {
        $this->createUser(['read', 'write']);

        $task = ContactTask::factory()->create();

        $response = $this->put('/api/vaults/'.$task->contact->vault_id.'/tasks/'.$task->id.'/toggle');

        $response->assertResourceNotFound();
    }
}
